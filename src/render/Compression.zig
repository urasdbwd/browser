// Copyright (C) 2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

//! Adaptive HTTP response compression for render handoffs.
//!
//! Dynamic HTML is already held once in the bounded response buffer. This
//! module writes it through a small streaming encoder, avoiding a second
//! response-sized allocation. Brotli quality 0 is both the preferred wire
//! format and the lowest-memory Brotli mode; gzip level 1 is the compatibility
//! fallback. Small or high-entropy bodies stay identity encoded.

const std = @import("std");
const brotli = @import("brotli_encode");

const Compression = @This();

pub const min_input_bytes = 1024;
const brotli_window_bits = 18;
const stream_buffer_bytes = 16 * 1024;

pub const Encoding = enum {
    identity,
    gzip,
    br,

    pub fn contentEncoding(self: Encoding) ?[]const u8 {
        return switch (self) {
            .identity => null,
            .gzip => "gzip",
            .br => "br",
        };
    }
};

pub const Preferences = struct {
    br: u16 = 0,
    gzip: u16 = 0,
    identity: u16 = 1000,

    pub fn preferred(self: Preferences) Encoding {
        if (self.br > 0 and self.br >= self.gzip) return .br;
        if (self.gzip > 0) return .gzip;
        return .identity;
    }

    fn fallback(self: Preferences, first: Encoding) Encoding {
        return switch (first) {
            .br => if (self.gzip > 0) .gzip else .identity,
            .gzip => if (self.br > 0) .br else .identity,
            .identity => .identity,
        };
    }
};

/// Incrementally consume one or more Accept-Encoding field values. Explicit
/// codings override `*`; q-values are stored as integers in [0, 1000].
pub const Negotiator = struct {
    br: ?u16 = null,
    gzip: ?u16 = null,
    identity: ?u16 = null,
    wildcard: ?u16 = null,

    pub fn add(self: *Negotiator, value: []const u8) void {
        var entries = std.mem.splitScalar(u8, value, ',');
        while (entries.next()) |entry_raw| {
            var parts = std.mem.splitScalar(u8, entry_raw, ';');
            const name = std.mem.trim(u8, parts.next() orelse continue, &std.ascii.whitespace);
            if (name.len == 0) continue;

            var quality: u16 = 1000;
            while (parts.next()) |parameter_raw| {
                const parameter = std.mem.trim(u8, parameter_raw, &std.ascii.whitespace);
                const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
                const key = std.mem.trim(u8, parameter[0..equals], &std.ascii.whitespace);
                if (!std.ascii.eqlIgnoreCase(key, "q")) continue;
                quality = parseQuality(parameter[equals + 1 ..]);
                break;
            }

            if (std.ascii.eqlIgnoreCase(name, "br")) {
                self.br = maxQuality(self.br, quality);
            } else if (std.ascii.eqlIgnoreCase(name, "gzip") or std.ascii.eqlIgnoreCase(name, "x-gzip")) {
                self.gzip = maxQuality(self.gzip, quality);
            } else if (std.ascii.eqlIgnoreCase(name, "identity")) {
                self.identity = maxQuality(self.identity, quality);
            } else if (std.mem.eql(u8, name, "*")) {
                self.wildcard = maxQuality(self.wildcard, quality);
            }
        }
    }

    pub fn preferences(self: Negotiator) Preferences {
        const wildcard = self.wildcard orelse 0;
        return .{
            .br = self.br orelse wildcard,
            .gzip = self.gzip orelse wildcard,
            // Identity is acceptable by default, except for an explicit
            // identity;q=0 or a bare wildcard exclusion.
            .identity = self.identity orelse if (self.wildcard != null and wildcard == 0) 0 else 1000,
        };
    }
};

pub const Stream = struct {
    encoding: Encoding,
    brotli_state: ?*brotli.BrotliEncoderState = null,

    pub fn init(preferences: Preferences, input: []const u8) ?Stream {
        if ((input.len < min_input_bytes or !likelyCompressible(input)) and
            preferences.identity > 0 and preferences.identity >= preferences.br and
            preferences.identity >= preferences.gzip)
        {
            return .{ .encoding = .identity };
        }

        const first = preferences.preferred();
        if (first == .br) {
            if (initBrotli(input.len)) |state| {
                return .{ .encoding = .br, .brotli_state = state };
            }
        }

        const second = preferences.fallback(first);
        if (first == .gzip or second == .gzip) {
            return .{ .encoding = .gzip };
        }
        if (second == .br) {
            if (initBrotli(input.len)) |state| {
                return .{ .encoding = .br, .brotli_state = state };
            }
        }
        if (preferences.identity > 0) return .{ .encoding = .identity };
        return null;
    }

    pub fn deinit(self: *Stream) void {
        if (self.brotli_state) |state| {
            brotli.BrotliEncoderDestroyInstance(state);
            self.brotli_state = null;
        }
    }

    pub fn writeAll(self: *Stream, input: []const u8, writer: *std.Io.Writer) !void {
        return switch (self.encoding) {
            .identity => writer.writeAll(input),
            .gzip => writeGzip(input, writer),
            .br => writeBrotli(self.brotli_state orelse return error.CompressionFailed, input, writer),
        };
    }
};

fn initBrotli(input_len: usize) ?*brotli.BrotliEncoderState {
    const state = brotli.BrotliEncoderCreateInstance(null, null, null) orelse return null;

    if (brotli.BrotliEncoderSetParameter(
        state,
        @intCast(brotli.BROTLI_PARAM_MODE),
        @intCast(brotli.BROTLI_MODE_TEXT),
    ) == 0) {
        brotli.BrotliEncoderDestroyInstance(state);
        return null;
    }
    if (brotli.BrotliEncoderSetParameter(
        state,
        @intCast(brotli.BROTLI_PARAM_QUALITY),
        0,
    ) == 0) {
        brotli.BrotliEncoderDestroyInstance(state);
        return null;
    }
    if (brotli.BrotliEncoderSetParameter(
        state,
        @intCast(brotli.BROTLI_PARAM_LGWIN),
        brotli_window_bits,
    ) == 0) {
        brotli.BrotliEncoderDestroyInstance(state);
        return null;
    }
    if (input_len <= std.math.maxInt(u32) and brotli.BrotliEncoderSetParameter(
        state,
        @intCast(brotli.BROTLI_PARAM_SIZE_HINT),
        @intCast(input_len),
    ) == 0) {
        brotli.BrotliEncoderDestroyInstance(state);
        return null;
    }
    return state;
}

fn writeBrotli(state: *brotli.BrotliEncoderState, input: []const u8, writer: *std.Io.Writer) !void {
    var available_in = input.len;
    var next_in: [*c]const u8 = input.ptr;
    var output: [stream_buffer_bytes]u8 = undefined;

    while (brotli.BrotliEncoderIsFinished(state) == 0) {
        var available_out: usize = output.len;
        var next_out: [*c]u8 = &output;
        if (brotli.BrotliEncoderCompressStream(
            state,
            @intCast(brotli.BROTLI_OPERATION_FINISH),
            &available_in,
            &next_in,
            &available_out,
            &next_out,
            null,
        ) == 0) return error.CompressionFailed;

        const produced = output.len - available_out;
        if (produced > 0) try writer.writeAll(output[0..produced]);
    }
    if (available_in != 0) return error.CompressionFailed;
}

fn writeGzip(input: []const u8, writer: *std.Io.Writer) !void {
    // Flate's bit writer needs at least eight writable output bytes. Wrap the
    // caller so unbuffered and initially-empty allocating writers are valid,
    // while still draining incrementally to the socket.
    var output_buffer: [stream_buffer_bytes]u8 = undefined;
    var output = PassthroughWriter.init(writer, &output_buffer);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &output.writer,
        &history,
        .gzip,
        .fastest,
    );
    try compressor.writer.writeAll(input);
    try compressor.finish();
    try output.writer.flush();
}

const PassthroughWriter = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer,

    fn init(out: *std.Io.Writer, buffer: []u8) PassthroughWriter {
        return .{
            .out = out,
            .writer = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain },
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *PassthroughWriter = @alignCast(@fieldParentPtr("writer", w));
        const buffered_len = w.end;
        const written = try self.out.writeSplatHeader(w.buffered(), data, splat);

        if (written < buffered_len) {
            const remaining = w.buffer[written..buffered_len];
            @memmove(w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
            return 0;
        }

        w.end = 0;
        return written - buffered_len;
    }
};

/// Avoid spending codec CPU on already-compressed/base64-like payloads. Four
/// evenly spaced samples keep the scan bounded even at the 16 MiB desktop cap.
fn likelyCompressible(input: []const u8) bool {
    const sample_len = @min(input.len, 1024);
    var seen: [4]u64 = @splat(0);
    var structured: usize = 0;
    var adjacent_repeats: usize = 0;
    var control_bytes: usize = 0;
    var base64_bytes: usize = 0;
    var previous: ?u8 = null;

    for (0..sample_len) |i| {
        const index = if (sample_len == input.len)
            i
        else
            i * (input.len - 1) / (sample_len - 1);
        const byte = input[index];
        seen[byte / 64] |= @as(u64, 1) << @intCast(byte % 64);
        structured += @intFromBool(std.mem.indexOfScalar(u8, " <>/=\"'{}[],:;\r\n\t", byte) != null);
        control_bytes += @intFromBool((byte < ' ' and byte != '\r' and byte != '\n' and byte != '\t') or byte == 0x7f);
        base64_bytes += @intFromBool(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/' or byte == '=' or
            byte == '\r' or byte == '\n' or byte == '\t' or byte == ' ');
        if (previous == byte) adjacent_repeats += 1;
        previous = byte;
    }

    // A render response is text. Control-heavy data is almost certainly an
    // embedded/already-compressed payload and is not worth feeding to a codec.
    if (control_bytes > sample_len / 50) return false;
    // Large random Base64 payloads save little relative to their codec CPU.
    // Real HTML has substantially more markup/punctuation than this.
    const almost_all = sample_len - sample_len / 100;
    if (input[0] != '<' and base64_bytes >= almost_all and structured < sample_len / 32) return false;

    var distinct: usize = 0;
    for (seen) |word| distinct += @popCount(word);
    return distinct < 192 or structured + adjacent_repeats >= sample_len / 16;
}

fn maxQuality(existing: ?u16, candidate: u16) u16 {
    return @max(existing orelse 0, candidate);
}

fn parseQuality(raw: []const u8) u16 {
    const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (std.mem.eql(u8, value, "0")) return 0;
    if (std.mem.eql(u8, value, "1")) return 1000;
    if (value.len < 2 or value[1] != '.') return 0;

    if (value[0] == '1') {
        for (value[2..]) |digit| if (digit != '0') return 0;
        return 1000;
    }
    if (value[0] != '0') return 0;

    var quality: u16 = 0;
    var places: u2 = 0;
    for (value[2..]) |digit| {
        if (places == 3 or !std.ascii.isDigit(digit)) return 0;
        quality = quality * 10 + digit - '0';
        places += 1;
    }
    while (places < 3) : (places += 1) quality *= 10;
    return quality;
}

test "render compression: Accept-Encoding honors q values and wildcard" {
    var n: Negotiator = .{};
    n.add("gzip;q=0.8, br;q=1, identity;q=0.1");
    try std.testing.expectEqual(Encoding.br, n.preferences().preferred());

    n = .{};
    n.add("br;q=0, gzip; q=0.5");
    try std.testing.expectEqual(Encoding.gzip, n.preferences().preferred());

    n = .{};
    n.add("br;q=0, *;q=0.7");
    try std.testing.expectEqual(@as(u16, 0), n.preferences().br);
    try std.testing.expectEqual(@as(u16, 700), n.preferences().gzip);

    n = .{};
    n.add("br;q=0, gzip;q=0, identity;q=0");
    try std.testing.expectEqual(@as(u16, 0), n.preferences().identity);
    try std.testing.expect(Stream.init(n.preferences(), "small") == null);

    n = .{};
    n.add("br, identity;q=0");
    var forced = Stream.init(n.preferences(), "small").?;
    defer forced.deinit();
    try std.testing.expectEqual(Encoding.br, forced.encoding);
}

test "render compression: small and high-entropy bodies stay identity" {
    var small = Stream.init(.{ .br = 1000, .gzip = 1000 }, "small").?;
    defer small.deinit();
    try std.testing.expectEqual(Encoding.identity, small.encoding);

    var randomish: [2048]u8 = undefined;
    for (&randomish, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% i / 7);
    var entropy = Stream.init(.{ .br = 1000 }, &randomish).?;
    defer entropy.deinit();
    try std.testing.expectEqual(Encoding.identity, entropy.encoding);

    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var base64ish: [2048]u8 = undefined;
    for (&base64ish, 0..) |*byte, i| byte.* = alphabet[(i * 17 + i / 13) % alphabet.len];
    var encoded_data = Stream.init(.{ .br = 1000 }, &base64ish).?;
    defer encoded_data.deinit();
    try std.testing.expectEqual(Encoding.identity, encoded_data.encoding);
}

test "render compression: Brotli stream round trip" {
    const input = "<!doctype html><main>Lightpanda client render</main>" ** 256;
    var stream = Stream.init(.{ .br = 1000 }, input).?;
    defer stream.deinit();
    try std.testing.expectEqual(Encoding.br, stream.encoding);

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try stream.writeAll(input, &encoded.writer);
    try std.testing.expect(encoded.written().len < input.len);

    const decoder = @import("brotli_decode");
    var decoded = try std.testing.allocator.alloc(u8, input.len);
    defer std.testing.allocator.free(decoded);
    var decoded_len = decoded.len;
    try std.testing.expectEqual(
        @as(c_uint, decoder.BROTLI_DECODER_RESULT_SUCCESS),
        decoder.BrotliDecoderDecompress(
            encoded.written().len,
            encoded.written().ptr,
            &decoded_len,
            decoded.ptr,
        ),
    );
    try std.testing.expectEqualStrings(input, decoded[0..decoded_len]);
}

test "render compression: gzip stream round trip" {
    const input = "<!doctype html><p>gzip compatibility</p>" ** 256;
    var stream = Stream.init(.{ .gzip = 1000 }, input).?;
    defer stream.deinit();
    try std.testing.expectEqual(Encoding.gzip, stream.encoding);

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try stream.writeAll(input, &encoded.writer);

    var compressed_reader: std.Io.Reader = .fixed(encoded.written());
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&compressed_reader, .gzip, &history);
    // `allocRemaining` intentionally reports StreamTooLong when the stream is
    // exactly the limit, because it cannot yet prove EOF. Leave one byte for
    // that sentinel read.
    const decoded = try decompressor.reader.allocRemaining(std.testing.allocator, .limited(input.len + 1));
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}
