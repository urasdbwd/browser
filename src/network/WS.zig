// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const EMPTY_PONG = [_]u8{ 138, 0 };

// CLOSE, 2 length, code
pub const CLOSE_NORMAL = [_]u8{ 136, 2, 3, 232 }; // code: 1000
pub const CLOSE_GOING_AWAY = [_]u8{ 136, 2, 3, 233 }; // code: 1001
pub const CLOSE_TOO_BIG = [_]u8{ 136, 2, 3, 241 }; // 1009
pub const CLOSE_PROTOCOL_ERROR = [_]u8{ 136, 2, 3, 234 }; //code: 1002
pub const CLOSE_INVALID_DATA = [_]u8{ 136, 2, 3, 239 }; // code: 1007

const MAX_CONTROL_PAYLOAD = 125;
const MAX_DATA_FRAMES = 1024;

const Fragments = struct {
    type: Message.Type,
    message: std.ArrayList(u8),
    frame_count: usize,
};

pub const Message = struct {
    type: Type,
    data: []const u8,
    cleanup_fragment: bool,

    pub const Type = enum {
        text,
        binary,
        close,
        ping,
        pong,
    };
};

// These are the only websocket types that we're currently sending
pub const OpCode = enum(u8) {
    text = 128 | 1,
    close = 128 | 8,
    pong = 128 | 10,
};

// We'll grow our buffer up to cdp-max-message-size (default 1MB), but should
// try to reclaim some of that space. A lot of drivers send large messages
// upfront (e.g. page.addScriptToEvaluateOnNewDocument) and then settle into
// smaller messages. So after RECLAIM_AFTER messages which would fit in
// RECLAIM_TO, we'll shrink the buffer.
const RECLAIM_TO = 256 * 1024;
const RECLAIM_AFTER = 8;

// WebSocket message reader. Given websocket message, acts as an iterator that
// can return zero or more Messages. When next returns null, any incomplete
// message will remain in reader.data
pub fn Reader(comptime EXPECT_MASK: bool) type {
    return struct {
        allocator: Allocator,

        // position in buf of the start of the next message
        pos: usize = 0,

        // position in buf up until where we have valid data
        // (any new reads must be placed after this)
        len: usize = 0,

        max_message_size: usize,

        buf: []u8,

        fragments: ?Fragments = null,

        // consecutive messages we've received which fit i RECLAIM_TO
        small_message_streak: usize = 0,

        const Self = @This();

        pub fn init(allocator: Allocator, max_message_size: usize) !Self {
            _ = try maxFrameSize(max_message_size);
            // Connection also uses this buffer for the HTTP upgrade request.
            const buf = try allocator.alloc(u8, 16 * 1024);
            return .{
                .buf = buf,
                .allocator = allocator,
                .max_message_size = max_message_size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cleanup();
            self.allocator.free(self.buf);
        }

        pub fn cleanup(self: *Self) void {
            if (self.fragments) |*f| {
                f.message.deinit(self.allocator);
                self.fragments = null;
            }
        }

        pub fn readBuf(self: *Self) []u8 {
            // We might have read a partial http or websocket message.
            // Subsequent reads must read from where we left off.
            return self.buf[self.len..];
        }

        pub fn next(self: *Self) NextError!?Message {
            LOOP: while (true) {
                var buf = self.buf[self.pos..self.len];
                const frame = try self.parseFrame(buf) orelse return null;

                if (frame.frame_len > self.buf.len) {
                    self.buf = try growBuffer(
                        self.allocator,
                        self.buf,
                        self.len,
                        frame.frame_len,
                    );
                    return null;
                }
                if (buf.len < frame.frame_len) return null;

                const payload = buf[frame.header_len..frame.frame_len];
                if (comptime EXPECT_MASK) {
                    mask(buf[frame.header_len - 4 .. frame.header_len], payload);
                }

                self.pos += frame.frame_len;
                if (frame.payload_len < RECLAIM_TO) {
                    self.small_message_streak +|= 1;
                } else {
                    self.small_message_streak = 0;
                }

                if (frame.is_continuation) {
                    const fragments = &(self.fragments orelse return error.InvalidContinuation);
                    if (fragments.frame_count >= MAX_DATA_FRAMES) return error.TooManyFragments;
                    fragments.frame_count += 1;

                    if (payload.len > self.max_message_size - fragments.message.items.len) {
                        const full_len = fragments.message.items.len +| payload.len;
                        lp.log.warn(.cdp, "CDP message too big", .{ .type = "WS", .len = full_len, .hint = "See the --cdp-max-message-size <bytes>" });
                        return error.TooLarge;
                    }

                    const full_len = fragments.message.items.len + payload.len;
                    try fragments.message.ensureTotalCapacityPrecise(self.allocator, full_len);
                    fragments.message.appendSliceAssumeCapacity(payload);

                    if (frame.fin == false) {
                        // maybe we have more parts of the message waiting
                        continue :LOOP;
                    }

                    try validatePayload(fragments.type, fragments.message.items);
                    // this continuation is done!
                    return .{
                        .type = fragments.type,
                        .data = fragments.message.items,
                        .cleanup_fragment = true,
                    };
                }

                const can_be_fragmented = frame.message_type == .text or frame.message_type == .binary;
                if (self.fragments != null and can_be_fragmented) {
                    // if this isn't a continuation, then we can't have fragments
                    return error.NestedFragmentation;
                }

                if (frame.fin == false) {
                    // not continuation, and not fin. It has to be the first message
                    // in a fragmented message.
                    var fragments = Fragments{
                        .message = .empty,
                        .type = frame.message_type,
                        .frame_count = 1,
                    };
                    errdefer fragments.message.deinit(self.allocator);
                    try fragments.message.ensureTotalCapacityPrecise(self.allocator, payload.len);
                    fragments.message.appendSliceAssumeCapacity(payload);
                    self.fragments = fragments;
                    continue :LOOP;
                }

                try validatePayload(frame.message_type, payload);
                return .{
                    .data = payload,
                    .type = frame.message_type,
                    .cleanup_fragment = false,
                };
            }
        }

        const Frame = struct {
            message_type: Message.Type,
            is_continuation: bool,
            fin: bool,
            header_len: usize,
            payload_len: usize,
            frame_len: usize,
        };

        fn parseFrame(self: *Self, buf: []const u8) NextError!?Frame {
            if (buf.len < 2) return null;

            const byte1 = buf[0];
            if (byte1 & 0x70 != 0) return error.ReservedFlags;

            const opcode = byte1 & 0x0f;
            const is_continuation = opcode == 0;
            const is_control = opcode >= 8;
            const message_type: Message.Type = switch (opcode) {
                0 => undefined,
                1 => .text,
                2 => .binary,
                8 => .close,
                9 => .ping,
                10 => .pong,
                else => return error.InvalidMessageType,
            };

            const fin = byte1 & 0x80 != 0;
            if (is_control and !fin) return error.FragmentedControl;

            const byte2 = buf[1];
            if (comptime EXPECT_MASK) {
                if (byte2 & 0x80 == 0) return error.NotMasked;
            } else if (byte2 & 0x80 != 0) {
                return error.Masked;
            }

            const length_code = byte2 & 0x7f;
            if (is_control and length_code > MAX_CONTROL_PAYLOAD) return error.ControlTooLarge;

            const length_of_len: usize = switch (length_code) {
                126 => 2,
                127 => 8,
                else => 0,
            };
            if (buf.len < 2 + length_of_len) return null;

            const payload_len_u64: u64 = switch (length_of_len) {
                2 => std.mem.readInt(u16, buf[2..4], .big),
                8 => std.mem.readInt(u64, buf[2..10], .big),
                else => length_code,
            };
            if (length_code == 126 and payload_len_u64 < 126) return error.NonCanonicalLength;
            if (length_code == 127) {
                if (payload_len_u64 & (@as(u64, 1) << 63) != 0) return error.InvalidLength;
                if (payload_len_u64 < 65536) return error.NonCanonicalLength;
            }

            if (!is_control and payload_len_u64 > self.max_message_size) {
                lp.log.warn(.cdp, "CDP message too big", .{ .type = "WS", .len = payload_len_u64, .hint = "See the --cdp-max-message-size <bytes>" });
                return error.TooLarge;
            }
            if (payload_len_u64 > std.math.maxInt(usize)) return error.TooLarge;

            const payload_len: usize = @intCast(payload_len_u64);
            const header_len = 2 + length_of_len + if (comptime EXPECT_MASK) 4 else 0;
            const frame_len = std.math.add(usize, header_len, payload_len) catch return error.TooLarge;
            if (buf.len < header_len) return null;

            return .{
                .message_type = message_type,
                .is_continuation = is_continuation,
                .fin = fin,
                .header_len = header_len,
                .payload_len = payload_len,
                .frame_len = frame_len,
            };
        }

        fn validatePayload(message_type: Message.Type, payload: []const u8) NextError!void {
            switch (message_type) {
                .text => if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8,
                .close => {
                    if (payload.len == 1) return error.InvalidClosePayload;
                    if (payload.len == 0) return;

                    const code = std.mem.readInt(u16, payload[0..2], .big);
                    if (!validCloseCode(code)) return error.InvalidCloseCode;
                    if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.InvalidUtf8;
                },
                .binary, .ping, .pong => {},
            }
        }

        fn validCloseCode(code: u16) bool {
            return switch (code) {
                1000...1003,
                1007...1014,
                3000...4999,
                => true,
                else => false,
            };
        }

        // This is called after we've processed complete websocket messages (this
        // only applies to websocket messages).
        // There are two cases:
        // 1 - We don't have any incomplete data (for a subsequent message) in buf.
        //     This is the easier to handle, we can set pos & len to 0.
        // 2 - We have part of the next message after consumed frames. Move it to
        //     the start so future socket reads always make progress.
        pub fn compact(self: *Self) void {
            const pos = self.pos;
            const len = self.len;

            lp.assert(pos <= len, "Client.Reader.compact precondition", .{ .pos = pos, .len = len });

            // how many (if any) partial bytes do we have
            const partial_bytes = len - pos;

            if (partial_bytes == 0) {
                // We have no partial bytes. Setting these to 0 ensures that we
                // get the best utilization of our buffer
                self.pos = 0;
                self.len = 0;
                self.maybeReclaim();
                return;
            }

            if (pos == 0) return;

            // Move a partial frame once, after any complete frames before it
            // have been consumed. Later reads leave it at offset zero.
            std.mem.copyForwards(u8, self.buf, self.buf[pos..len]);
            self.pos = 0;
            self.len = partial_bytes;
        }

        fn maybeReclaim(self: *Self) void {
            const max_frame_size = maxFrameSize(self.max_message_size) catch return;
            const floor = @min(RECLAIM_TO, max_frame_size);
            if (self.buf.len <= floor or self.small_message_streak < RECLAIM_AFTER) {
                return;
            }

            self.buf = self.allocator.remap(self.buf, floor) orelse blk: {
                const smaller = self.allocator.alloc(u8, floor) catch return;
                self.allocator.free(self.buf);
                break :blk smaller;
            };
            self.small_message_streak = 0;
        }

        fn maxFrameSize(max_message_size: usize) error{TooLarge}!usize {
            const max_payload = @max(max_message_size, MAX_CONTROL_PAYLOAD);
            const max_header: usize = if (comptime EXPECT_MASK) 14 else 10;
            return std.math.add(usize, max_payload, max_header) catch error.TooLarge;
        }
    };
}

// Map a reader error (or any error that flowed up out of one) to the
// matching server→client close frame. Takes anyerror so callers that
// hold the error in a wider type (e.g. ?anyerror across an inbox)
// don't need to narrow it first; unrecognized errors return null.
pub fn errorReply(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.TooLarge,
        error.TooManyFragments,
        => &CLOSE_TOO_BIG,
        error.InvalidUtf8 => &CLOSE_INVALID_DATA,
        error.Masked,
        error.NotMasked,
        error.ReservedFlags,
        error.InvalidMessageType,
        error.ControlTooLarge,
        error.FragmentedControl,
        error.InvalidContinuation,
        error.NestedFragmentation,
        error.NonCanonicalLength,
        error.InvalidLength,
        error.InvalidClosePayload,
        error.InvalidCloseCode,
        // Strictly an application-level (CDP) error, but 1002
        // "protocol error" is the closest fit and gives the peer a
        // cleaner signal than a bare TCP FIN.
        error.InvalidJSON,
        => &CLOSE_PROTOCOL_ERROR,
        else => null,
    };
}

const NextError = error{
    TooLarge,
    Masked,
    NotMasked,
    ReservedFlags,
    InvalidMessageType,
    ControlTooLarge,
    FragmentedControl,
    InvalidContinuation,
    NestedFragmentation,
    NonCanonicalLength,
    InvalidLength,
    InvalidClosePayload,
    InvalidCloseCode,
    InvalidUtf8,
    TooManyFragments,
    OutOfMemory,
};

fn growBuffer(
    allocator: Allocator,
    buf: []u8,
    used_len: usize,
    required_capacity: usize,
) ![]u8 {
    std.debug.assert(used_len <= buf.len);
    lp.log.debug(.app, "CDP buffer growth", .{ .from = buf.len, .to = required_capacity });

    if (allocator.resize(buf, required_capacity)) {
        return buf.ptr[0..required_capacity];
    }
    const new_buffer = try allocator.alloc(u8, required_capacity);
    @memcpy(new_buffer[0..used_len], buf[0..used_len]);
    allocator.free(buf);
    return new_buffer;
}

// Zig is in a weird backend transition right now. Need to determine if
// SIMD is even available.
const backend_supports_vectors = switch (builtin.zig_backend) {
    .stage2_llvm, .stage2_c => true,
    else => false,
};

// Websocket messages from client->server are masked using a 4 byte XOR mask
fn mask(m: []const u8, payload: []u8) void {
    var data = payload;

    if (!comptime backend_supports_vectors) return simpleMask(m, data);

    const vector_size = std.simd.suggestVectorLength(u8) orelse @sizeOf(usize);
    if (data.len >= vector_size) {
        const mask_vector = std.simd.repeat(vector_size, @as(@Vector(4, u8), m[0..4].*));
        while (data.len >= vector_size) {
            const slice = data[0..vector_size];
            const masked_data_slice: @Vector(vector_size, u8) = slice.*;
            slice.* = masked_data_slice ^ mask_vector;
            data = data[vector_size..];
        }
    }
    simpleMask(m, data);
}

// Used when SIMD isn't available, or for any remaining part of the message
// which is too small to effectively use SIMD.
fn simpleMask(m: []const u8, payload: []u8) void {
    for (payload, 0..) |b, i| {
        payload[i] = b ^ m[i & 3];
    }
}

const testing = std.testing;
test "mask" {
    var buf: [4000]u8 = undefined;
    const messages = [_][]const u8{ "1234", "1234" ** 99, "1234" ** 999 };
    for (messages) |message| {
        // we need the message to be mutable since mask operates in-place
        const payload = buf[0..message.len];
        @memcpy(payload, message);

        mask(&.{ 1, 2, 200, 240 }, payload);
        try testing.expectEqual(false, std.mem.eql(u8, payload, message));

        mask(&.{ 1, 2, 200, 240 }, payload);
        try testing.expectEqual(true, std.mem.eql(u8, payload, message));
    }
}

// Builds an unmasked (server->client) text frame.
fn writeFrame(list: *std.ArrayList(u8), allocator: Allocator, payload: []const u8) !void {
    try list.append(allocator, @intFromEnum(OpCode.text)); // FIN + text opcode
    if (payload.len <= 125) {
        try list.append(allocator, @intCast(payload.len));
    } else if (payload.len <= 65535) {
        try list.append(allocator, 126);
        try list.append(allocator, @intCast((payload.len >> 8) & 0xff));
        try list.append(allocator, @intCast(payload.len & 0xff));
    } else {
        try list.append(allocator, 127);
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            try list.append(allocator, @intCast((payload.len >> @intCast(i * 8)) & 0xff));
        }
    }
    try list.appendSlice(allocator, payload);
}

fn appendMaskedTestFrame(
    list: *std.ArrayList(u8),
    allocator: Allocator,
    first_byte: u8,
    payload: []const u8,
    mask_key: [4]u8,
) !void {
    try list.append(allocator, first_byte);
    if (payload.len <= 125) {
        try list.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 65535) {
        try list.append(allocator, 0x80 | 126);
        try list.append(allocator, @intCast((payload.len >> 8) & 0xff));
        try list.append(allocator, @intCast(payload.len & 0xff));
    } else {
        try list.append(allocator, 0x80 | 127);
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            try list.append(allocator, @intCast((payload.len >> @intCast(i * 8)) & 0xff));
        }
    }

    try list.appendSlice(allocator, &mask_key);
    const payload_start = list.items.len;
    try list.appendSlice(allocator, payload);
    mask(&mask_key, list.items[payload_start..]);
}

fn appendMaskedTestFrameWithLength(
    list: *std.ArrayList(u8),
    allocator: Allocator,
    first_byte: u8,
    length_code: u8,
    extended_length: []const u8,
    payload: []const u8,
    mask_key: [4]u8,
) !void {
    try list.append(allocator, first_byte);
    try list.append(allocator, 0x80 | length_code);
    try list.appendSlice(allocator, extended_length);
    try list.appendSlice(allocator, &mask_key);
    const payload_start = list.items.len;
    try list.appendSlice(allocator, payload);
    mask(&mask_key, list.items[payload_start..]);
}

fn feedTestFrame(reader: anytype, frame: []const u8) !?Message {
    var offset: usize = 0;
    while (true) {
        const dst = reader.readBuf();
        if (dst.len > 0 and offset < frame.len) {
            const n = @min(dst.len, frame.len - offset);
            @memcpy(dst[0..n], frame[offset..][0..n]);
            reader.len += n;
            offset += n;
        }

        if (try reader.next()) |message| return message;
        if (offset == frame.len) return null;
        reader.compact();
    }
}

fn expectTestFrameError(comptime expected: anyerror, max_message_size: usize, frame: []const u8) !void {
    var reader = try Reader(true).init(testing.allocator, max_message_size);
    defer reader.deinit();
    try testing.expectError(expected, feedTestFrame(&reader, frame));
}

// Drives one complete frame through the reader the way Connection does:
// feed bytes (growing when next() asks for room), drain complete messages,
// then compact.
fn feedAndDrain(reader: anytype, frame: []const u8) !void {
    var offset: usize = 0;
    while (true) {
        const free = reader.readBuf();
        if (free.len > 0 and offset < frame.len) {
            const n = @min(free.len, frame.len - offset);
            @memcpy(free[0..n], frame[offset..][0..n]);
            reader.len += n;
            offset += n;
        }
        if (try reader.next()) |_| {
            continue;
        }
        if (offset >= frame.len) {
            break;
        }
    }
    reader.compact();
}

test "WS reader: reassembles fragmented text with interleaved controls" {
    const allocator = testing.allocator;
    var reader = try Reader(true).init(allocator, 64);
    defer reader.deinit();

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);

    try appendMaskedTestFrame(&frame, allocator, 0x01, "hel", .{ 1, 2, 3, 4 });
    try testing.expectEqual(null, try feedTestFrame(&reader, frame.items));
    reader.compact();

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x89, "?", .{ 5, 6, 7, 8 });
    const ping = (try feedTestFrame(&reader, frame.items)) orelse return error.ExpectedPing;
    try testing.expectEqual(.ping, ping.type);
    try testing.expectEqualStrings("?", ping.data);
    reader.compact();

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x8a, "!", .{ 9, 10, 11, 12 });
    const pong = (try feedTestFrame(&reader, frame.items)) orelse return error.ExpectedPong;
    try testing.expectEqual(.pong, pong.type);
    try testing.expectEqualStrings("!", pong.data);
    reader.compact();

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x00, "lo ", .{ 13, 14, 15, 16 });
    try testing.expectEqual(null, try feedTestFrame(&reader, frame.items));
    reader.compact();

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x80, "world", .{ 17, 18, 19, 20 });
    const text = (try feedTestFrame(&reader, frame.items)) orelse return error.ExpectedText;
    try testing.expectEqual(.text, text.type);
    try testing.expectEqualStrings("hello world", text.data);
    try testing.expect(text.cleanup_fragment);
    reader.cleanup();
    reader.compact();
}

test "WS reader: enforces continuation sequencing" {
    const allocator = testing.allocator;
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);

    try appendMaskedTestFrame(&frame, allocator, 0x80, "", .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.InvalidContinuation, 16, frame.items);

    frame.clearRetainingCapacity();
    var nested_reader = try Reader(true).init(allocator, 16);
    defer nested_reader.deinit();
    try appendMaskedTestFrame(&frame, allocator, 0x01, "a", .{ 1, 2, 3, 4 });
    try testing.expectEqual(null, try feedTestFrame(&nested_reader, frame.items));
    nested_reader.compact();
    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x82, "b", .{ 5, 6, 7, 8 });
    try testing.expectError(error.NestedFragmentation, feedTestFrame(&nested_reader, frame.items));

    frame.clearRetainingCapacity();
    var completed_reader = try Reader(true).init(allocator, 16);
    defer completed_reader.deinit();
    try appendMaskedTestFrame(&frame, allocator, 0x01, "a", .{ 1, 2, 3, 4 });
    try testing.expectEqual(null, try feedTestFrame(&completed_reader, frame.items));
    completed_reader.compact();
    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x80, "b", .{ 5, 6, 7, 8 });
    const completed = (try feedTestFrame(&completed_reader, frame.items)) orelse return error.ExpectedText;
    try testing.expectEqualStrings("ab", completed.data);
    completed_reader.cleanup();
    completed_reader.compact();

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x80, "c", .{ 9, 10, 11, 12 });
    try testing.expectError(error.InvalidContinuation, feedTestFrame(&completed_reader, frame.items));
}

test "WS reader: validates frame header and controls" {
    const allocator = testing.allocator;
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);

    for ([_]u8{ 0xc1, 0xa1, 0x91 }) |first_byte| {
        frame.clearRetainingCapacity();
        try appendMaskedTestFrame(&frame, allocator, first_byte, "", .{ 1, 2, 3, 4 });
        try expectTestFrameError(error.ReservedFlags, 128, frame.items);
    }

    for ([_]u8{ 3, 7, 11, 15 }) |opcode| {
        frame.clearRetainingCapacity();
        try appendMaskedTestFrame(&frame, allocator, 0x80 | opcode, "", .{ 1, 2, 3, 4 });
        try expectTestFrameError(error.InvalidMessageType, 128, frame.items);
    }

    try expectTestFrameError(error.NotMasked, 128, &.{ 0x81, 0x00 });
    try expectTestFrameError(error.NotMasked, 128, &.{ 0x89, 0x00 });

    frame.clearRetainingCapacity();
    try appendMaskedTestFrameWithLength(&frame, allocator, 0x81, 126, &.{ 0, 125 }, "", .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.NonCanonicalLength, 65536, frame.items);

    frame.clearRetainingCapacity();
    try appendMaskedTestFrameWithLength(&frame, allocator, 0x81, 127, &.{ 0, 0, 0, 0, 0, 0, 255, 255 }, "", .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.NonCanonicalLength, 65536, frame.items);

    frame.clearRetainingCapacity();
    try appendMaskedTestFrameWithLength(&frame, allocator, 0x81, 127, &.{ 128, 0, 0, 0, 0, 0, 0, 0 }, "", .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.InvalidLength, 65536, frame.items);

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x09, "", .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.FragmentedControl, 128, frame.items);

    frame.clearRetainingCapacity();
    const ping_payload = "p" ** 125;
    try appendMaskedTestFrame(&frame, allocator, 0x89, ping_payload, .{ 1, 2, 3, 4 });
    var reader = try Reader(true).init(allocator, 1);
    defer reader.deinit();
    const ping = (try feedTestFrame(&reader, frame.items)) orelse return error.ExpectedPing;
    try testing.expectEqual(.ping, ping.type);
    try testing.expectEqualStrings(ping_payload, ping.data);

    frame.clearRetainingCapacity();
    try appendMaskedTestFrameWithLength(&frame, allocator, 0x89, 126, &.{ 0, 126 }, "", .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.ControlTooLarge, 128, frame.items);
    try testing.expectEqualSlices(u8, &CLOSE_PROTOCOL_ERROR, errorReply(error.ControlTooLarge).?);
}

test "WS reader: validates close payload and UTF-8" {
    const allocator = testing.allocator;
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);

    var reader = try Reader(true).init(allocator, 32);
    defer reader.deinit();

    try appendMaskedTestFrame(&frame, allocator, 0x88, "", .{ 1, 2, 3, 4 });
    const empty_close = (try feedTestFrame(&reader, frame.items)) orelse return error.ExpectedClose;
    try testing.expectEqual(.close, empty_close.type);
    try testing.expectEqual(0, empty_close.data.len);
    reader.compact();

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x88, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, .{ 5, 6, 7, 8 });
    const reason_close = (try feedTestFrame(&reader, frame.items)) orelse return error.ExpectedClose;
    try testing.expectEqual(.close, reason_close.type);
    try testing.expectEqualSlices(u8, &.{ 0x03, 0xe8, 'b', 'y', 'e' }, reason_close.data);
    reader.compact();

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x88, &.{0x03}, .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.InvalidClosePayload, 32, frame.items);

    for ([_]u16{ 999, 1005, 1006, 1015, 1016, 5000 }) |code| {
        const close_payload = [2]u8{ @intCast(code >> 8), @intCast(code & 0xff) };
        frame.clearRetainingCapacity();
        try appendMaskedTestFrame(&frame, allocator, 0x88, &close_payload, .{ 1, 2, 3, 4 });
        try expectTestFrameError(error.InvalidCloseCode, 32, frame.items);
    }

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x88, &.{ 0x03, 0xe8, 0xff }, .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.InvalidUtf8, 32, frame.items);

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x81, &.{ 0xc3, 0x28 }, .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.InvalidUtf8, 32, frame.items);
    try testing.expectEqualSlices(u8, &CLOSE_INVALID_DATA, errorReply(error.InvalidUtf8).?);

    frame.clearRetainingCapacity();
    var fragmented_reader = try Reader(true).init(allocator, 8);
    defer fragmented_reader.deinit();
    try appendMaskedTestFrame(&frame, allocator, 0x01, &.{ 0xf0, 0x9f }, .{ 1, 2, 3, 4 });
    try testing.expectEqual(null, try feedTestFrame(&fragmented_reader, frame.items));
    fragmented_reader.compact();
    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x80, &.{ 0x92, 0xa9 }, .{ 5, 6, 7, 8 });
    const scalar = (try feedTestFrame(&fragmented_reader, frame.items)) orelse return error.ExpectedText;
    try testing.expectEqualSlices(u8, &.{ 0xf0, 0x9f, 0x92, 0xa9 }, scalar.data);
    fragmented_reader.cleanup();
    fragmented_reader.compact();
}

test "WS reader: max size counts reassembled payload" {
    const allocator = testing.allocator;
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);

    var exact_reader = try Reader(true).init(allocator, 8);
    defer exact_reader.deinit();
    try testing.expect(exact_reader.buf.len <= 16 * 1024);

    try appendMaskedTestFrame(&frame, allocator, 0x82, "12345678", .{ 1, 2, 3, 4 });
    const exact = (try feedTestFrame(&exact_reader, frame.items)) orelse return error.ExpectedBinary;
    try testing.expectEqualStrings("12345678", exact.data);
    exact_reader.compact();

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x82, "123456789", .{ 1, 2, 3, 4 });
    try expectTestFrameError(error.TooLarge, 8, frame.items);

    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x02, "123", .{ 1, 2, 3, 4 });
    try testing.expectEqual(null, try feedTestFrame(&exact_reader, frame.items));
    exact_reader.compact();
    try testing.expectEqual(@as(usize, 3), exact_reader.fragments.?.message.capacity);
    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x80, "45678", .{ 5, 6, 7, 8 });
    const fragmented_exact = (try feedTestFrame(&exact_reader, frame.items)) orelse return error.ExpectedBinary;
    try testing.expectEqualStrings("12345678", fragmented_exact.data);
    try testing.expect(exact_reader.fragments.?.message.capacity <= 8);
    exact_reader.cleanup();
    exact_reader.compact();

    frame.clearRetainingCapacity();
    var oversized_fragments = try Reader(true).init(allocator, 8);
    defer oversized_fragments.deinit();
    try appendMaskedTestFrame(&frame, allocator, 0x02, "123", .{ 1, 2, 3, 4 });
    try testing.expectEqual(null, try feedTestFrame(&oversized_fragments, frame.items));
    oversized_fragments.compact();
    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x80, "456789", .{ 5, 6, 7, 8 });
    try testing.expectError(error.TooLarge, feedTestFrame(&oversized_fragments, frame.items));

    frame.clearRetainingCapacity();
    try appendMaskedTestFrameWithLength(&frame, allocator, 0x82, 126, &.{ 0x10, 0x00 }, "", .{ 1, 2, 3, 4 });
    var declared_reader = try Reader(true).init(allocator, 8);
    defer declared_reader.deinit();
    const capacity_before = declared_reader.buf.len;
    try testing.expectError(error.TooLarge, feedTestFrame(&declared_reader, frame.items));
    try testing.expectEqual(capacity_before, declared_reader.buf.len);

    const large_payload = try allocator.alloc(u8, 65537);
    defer allocator.free(large_payload);
    @memset(large_payload, 'x');
    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x82, large_payload, .{ 1, 2, 3, 4 });
    var large_reader = try Reader(true).init(allocator, large_payload.len);
    defer large_reader.deinit();
    const large = (try feedTestFrame(&large_reader, frame.items)) orelse return error.ExpectedBinary;
    try testing.expectEqual(large_payload.len, large.data.len);
    try testing.expectEqualStrings(large_payload, large.data);
    try testing.expect(large_reader.buf.len <= large_payload.len + 14);

    frame.clearRetainingCapacity();
    var fragment_limit_reader = try Reader(true).init(allocator, 1);
    defer fragment_limit_reader.deinit();
    try appendMaskedTestFrame(&frame, allocator, 0x01, "", .{ 1, 2, 3, 4 });
    try testing.expectEqual(null, try feedTestFrame(&fragment_limit_reader, frame.items));
    fragment_limit_reader.compact();
    for (1..MAX_DATA_FRAMES) |_| {
        frame.clearRetainingCapacity();
        try appendMaskedTestFrame(&frame, allocator, 0x00, "", .{ 1, 2, 3, 4 });
        try testing.expectEqual(null, try feedTestFrame(&fragment_limit_reader, frame.items));
        fragment_limit_reader.compact();
    }
    frame.clearRetainingCapacity();
    try appendMaskedTestFrame(&frame, allocator, 0x80, "", .{ 1, 2, 3, 4 });
    try testing.expectError(error.TooManyFragments, feedTestFrame(&fragment_limit_reader, frame.items));
    try testing.expectEqualSlices(u8, &CLOSE_TOO_BIG, errorReply(error.TooManyFragments).?);
}

test "reader: reclaims buffer after a run of small messages" {
    const allocator = testing.allocator;
    var reader = try Reader(false).init(allocator, 4 * 1024 * 1024);
    defer reader.deinit();

    // A large message forces the buffer to grow well past RECLAIM_TO.
    const big_payload = try allocator.alloc(u8, RECLAIM_TO + 100 * 1024);
    defer allocator.free(big_payload);
    @memset(big_payload, 'a');

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(allocator);
    try writeFrame(&big, allocator, big_payload);

    try feedAndDrain(&reader, big.items);
    try testing.expect(reader.buf.len > RECLAIM_TO);
    try testing.expectEqual(@as(usize, 0), reader.small_message_streak);

    // A whole run of small messages delivered in a *single* batch must count
    // as individual messages, not as one compaction — reads don't align with
    // message boundaries over TCP. Stop one short of the threshold.
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(allocator);
    for (0..RECLAIM_AFTER - 1) |_| {
        try writeFrame(&batch, allocator, "hello");
    }
    try feedAndDrain(&reader, batch.items);
    try testing.expectEqual(@as(usize, RECLAIM_AFTER - 1), reader.small_message_streak);
    try testing.expect(reader.buf.len > RECLAIM_TO);

    // One more small message tips the run over the threshold and shrinks.
    var small: std.ArrayList(u8) = .empty;
    defer small.deinit(allocator);
    try writeFrame(&small, allocator, "hello");
    try feedAndDrain(&reader, small.items);
    try testing.expectEqual(@as(usize, RECLAIM_TO), reader.buf.len);

    // A later large message resets the run and re-grows the buffer.
    try feedAndDrain(&reader, big.items);
    try testing.expect(reader.buf.len > RECLAIM_TO);
    try testing.expectEqual(@as(usize, 0), reader.small_message_streak);
}
