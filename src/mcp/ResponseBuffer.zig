// Copyright (C) 2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

//! Transactional, dynamically growing writer with a hard capacity.
//!
//! A producer may leave partial data when a write crosses the limit. The
//! consumer checks `failed`, ignores `buffered()` in that case, emits a small
//! static error, and closes the connection.

const std = @import("std");

const ResponseBuffer = @This();

out: std.Io.Writer.Allocating,
writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &vtable },
limit: usize,
failure: ?Failure = null,

pub const Failure = enum {
    limit,
    out_of_memory,
};

const vtable: std.Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
};

pub fn init(allocator: std.mem.Allocator, limit: usize) ResponseBuffer {
    return .{ .out = .init(allocator), .limit = limit };
}

pub fn deinit(self: *ResponseBuffer) void {
    self.out.deinit();
}

pub fn buffered(self: *const ResponseBuffer) []const u8 {
    return self.out.writer.buffered();
}

pub fn reset(self: *ResponseBuffer, retained_bytes: usize) void {
    if (self.out.writer.buffer.len <= retained_bytes) {
        self.out.clearRetainingCapacity();
    } else {
        const allocator = self.out.allocator;
        self.out.deinit();
        self.out = .init(allocator);
    }
    self.failure = null;
    self.writer.end = 0;
}

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *ResponseBuffer = @alignCast(@fieldParentPtr("writer", writer));
    if (self.failure != null) return error.WriteFailed;

    var additional: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        additional = std.math.add(usize, additional, bytes.len) catch
            return self.fail(.limit);
    }
    const splat_bytes = std.math.mul(usize, data[data.len - 1].len, splat) catch
        return self.fail(.limit);
    additional = std.math.add(usize, additional, splat_bytes) catch
        return self.fail(.limit);

    const current = self.out.writer.end;
    if (additional > self.limit or current > self.limit - additional) {
        return self.fail(.limit);
    }
    const needed = current + additional;
    if (self.out.writer.buffer.len < needed) {
        const capacity = @min(std.ArrayList(u8).growCapacity(needed), self.limit);
        self.out.ensureTotalCapacityPrecise(capacity) catch
            return self.fail(.out_of_memory);
    }

    return self.out.writer.writeSplat(data, splat) catch
        return self.fail(.out_of_memory);
}

fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {}

fn fail(self: *ResponseBuffer, failure: Failure) error{WriteFailed} {
    self.failure = failure;
    return error.WriteFailed;
}

test "ResponseBuffer: limit failure is transactional" {
    var out: ResponseBuffer = .init(std.testing.allocator, 16);
    defer out.deinit();

    try out.writer.writeAll("1234567890");
    try std.testing.expectError(error.WriteFailed, out.writer.writeAll("1234567"));
    try std.testing.expectEqual(Failure.limit, out.failure.?);
    try std.testing.expectEqualStrings("1234567890", out.buffered());
    try std.testing.expect(out.out.writer.buffer.len <= 16);

    out.reset(16);
    try std.testing.expectEqual(null, out.failure);
    try std.testing.expectEqualStrings("", out.buffered());
    try out.writer.writeAll("ok");
    try std.testing.expectEqualStrings("ok", out.buffered());
}

test "ResponseBuffer: allocation failure is distinct from the size limit" {
    var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    tracked.fail_index = tracked.alloc_index;
    var out: ResponseBuffer = .init(tracked.allocator(), 16);
    defer out.deinit();

    try std.testing.expectError(error.WriteFailed, out.writer.writeAll("x"));
    try std.testing.expectEqual(Failure.out_of_memory, out.failure.?);
    try std.testing.expectEqualStrings("", out.buffered());
}

test "ResponseBuffer: reset releases oversized retained capacity" {
    var out: ResponseBuffer = .init(std.testing.allocator, 128 * 1024);
    defer out.deinit();

    try out.writer.splatByteAll('x', 64 * 1024 + 1);
    try std.testing.expect(out.out.writer.buffer.len > 64 * 1024);
    out.reset(64 * 1024);
    try std.testing.expectEqual(0, out.out.writer.buffer.len);
}
