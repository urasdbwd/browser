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

// Thread-safe FIFO of Messages. Producer pushes from one thread,
// consumer pops from another. No wake mechanism is bundled — callers
// arrange that themselves (e.g. curl_multi_wakeup on the consumer's
// curl multi handle).
//
// Intrusive singly-linked FIFO. The allowlist-during-sync-wait drain already
// walks from the head to find a matching message, so retaining a back-link in
// every queued message only wastes memory. A tail pointer keeps push O(1), and
// carrying the previous pointer during that walk keeps removal O(1) once found.

const std = @import("std");
const lp = @import("lightpanda");

const CDP = @import("cdp/CDP.zig");

const Inbox = @This();

mutex: std.Io.Mutex = .init,
first: ?*Message = null,
last: ?*Message = null,

// Number of queued commands/control frames that interrupt nested network waits.
// Maintaining it on push/pop makes the hot-path check O(1) instead of rescanning
// all queued CDP commands on every tick.
pending_teardowns: usize = 0,

// One-way latch, set by the worker's drainInbox the first time it
// observes a .disconnect (or .close) and never cleared. Ensures that, on
// multiple drains, the terminated state is preserved / communicated. This is
// specifically meant to handle the case where a disconnect is captured during
// a syncRequest and we want the following non-nested tick to pick it up again.
terminated: bool = false,

pub fn deinit(self: *Inbox) void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    while (self.popUnlocked()) |msg| {
        msg.deinit();
    }
}

pub fn push(self: *Inbox, arena: *lp.Arena, payload: Message.Payload) void {
    const msg = arena.create(Message) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };

    const is_teardown = isTeardown(payload);
    msg.* = .{ .payload = payload, .arena = arena };
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);

    if (is_teardown) self.pending_teardowns += 1;

    if (self.last) |last| {
        last.next = msg;
    } else {
        self.first = msg;
    }
    self.last = msg;
}

pub fn pop(self: *Inbox) ?*Message {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    return self.popUnlocked();
}

fn popUnlocked(self: *Inbox) ?*Message {
    const msg = self.first orelse return null;
    self.first = msg.next;
    if (self.first == null) self.last = null;
    msg.next = null;
    if (self.pending_teardowns != 0 and isTeardown(msg.payload)) self.pending_teardowns -= 1;
    return msg;
}

pub fn hasTeardown(self: *Inbox) bool {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    return self.pending_teardowns != 0;
}

fn isTeardown(payload: Message.Payload) bool {
    return switch (payload) {
        .close, .disconnect => true,
        .ping => false,
        .cdp => |c| std.mem.eql(u8, c.input.method, "Target.closeTarget") or
            std.mem.eql(u8, c.input.method, "Target.disposeBrowserContext") or
            std.mem.eql(u8, c.input.method, "Page.close"),
    };
}

// Generic peek for a message matching `predicate` without removing it. Teardown
// checks should use hasTeardown(), which avoids this O(n) traversal.
pub fn contains(self: *Inbox, predicate: *const fn (*Message) bool) bool {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    var it = self.first;
    while (it) |msg| : (it = msg.next) {
        if (predicate(msg)) return true;
    }
    return false;
}

// Cherry-pick the first message for which `predicate(msg)` returns
// true, removing it from the queue. Walks the queue in FIFO order;
// non-matching messages stay in place. Used to dispatch only the
// safe subset of messages during sync-wait paths (the allowlist),
// while leaving unsafe ones to be drained at the next safe point.
pub fn popIf(self: *Inbox, predicate: *const fn (*Message) bool) ?*Message {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    var previous: ?*Message = null;
    var it = self.first;
    while (it) |msg| : (it = msg.next) {
        if (predicate(msg)) {
            if (previous) |prev| {
                prev.next = msg.next;
            } else {
                self.first = msg.next;
            }
            if (self.last == msg) self.last = previous;
            msg.next = null;
            if (self.pending_teardowns != 0 and isTeardown(msg.payload)) self.pending_teardowns -= 1;
            return msg;
        }
        previous = msg;
    }
    return null;
}

pub const Message = struct {
    arena: *lp.Arena,
    payload: Payload,
    next: ?*Message = null,

    pub const Payload = union(enum) {
        // A CDP text/binary frame, parsed on the Network thread. `raw`
        // is the original JSON bytes (owned). `arena` holds any
        // auxiliary allocations from parseFromSliceLeaky (typically
        // empty for unescaped messages, but slices in `input` may
        // reference it). `input` is the parsed view; its string
        // slices reference `raw` or `arena`. Both must outlive the
        // consumer's use of `input`.
        cdp: Cdp,

        // WS ping frame body (≤125 bytes per spec). Consumer is
        // expected to echo via pong on its thread.
        ping: []u8,

        // Peer-initiated close frame. Consumer is expected to send a
        // close reply and tear the connection down. The peer's close
        // body is dropped — historically we always reply CLOSE_NORMAL
        // (status 1000) regardless of what the peer sent.
        close: void,

        // No allocation; conveys "no more messages will arrive on
        // this inbox" plus an optional reason. The Network thread
        // pushes this on peer EOF, fatal WS framing error, or
        // (now) JSON parse failure.
        disconnect: ?anyerror,
    };

    pub const Cdp = struct {
        raw: []u8,
        input: CDP.InputMessage,
    };

    pub fn deinit(self: *const Message) void {
        self.arena.release();
    }
};

const testing = @import("testing.zig");
test "Inbox: push then pop returns FIFO order" {
    const arena_pool = &testing.test_app.arena_pool;

    var inbox = Inbox{};
    defer inbox.deinit();

    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "first") });
    }

    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "second") });
    }

    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .disconnect = null });
    }

    {
        const m = inbox.pop().?;
        defer m.deinit();
        try testing.expectEqual("first", m.payload.ping);
    }
    {
        const m = inbox.pop().?;
        defer m.deinit();
        try testing.expectEqual("second", m.payload.ping);
    }
    {
        const m = inbox.pop().?;
        defer m.deinit();
        try testing.expectEqual(@as(?anyerror, null), m.payload.disconnect);
    }
    try testing.expect(inbox.pop() == null);
}

test "Inbox: deinit frees remaining items" {
    const arena_pool = &testing.test_app.arena_pool;

    var inbox = Inbox{};
    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "leftover") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "inbox test");
        inbox.push(arena, .{ .disconnect = error.PeerClosed });
    }

    inbox.deinit();
    // Memory leaks would be caught by the test runner.
}

fn testAlwaysTrue(_: *Message) bool {
    return true;
}

fn testAlwaysFalse(_: *Message) bool {
    return false;
}

fn testIsPing(msg: *Message) bool {
    return msg.payload == .ping;
}

fn testIsDisconnect(msg: *Message) bool {
    return msg.payload == .disconnect;
}

test "Inbox: popIf on empty queue returns null" {
    var inbox = Inbox{};
    defer inbox.deinit();
    try testing.expect(inbox.popIf(testAlwaysTrue) == null);
}

test "Inbox: popIf with no match leaves queue intact" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit();

    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "first") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "second") });
    }

    try testing.expect(inbox.popIf(testAlwaysFalse) == null);

    // Original FIFO order preserved.
    {
        const m = inbox.pop().?;
        defer m.deinit();
        try testing.expectEqual("first", m.payload.ping);
    }
    {
        const m = inbox.pop().?;
        defer m.deinit();
        try testing.expectEqual("second", m.payload.ping);
    }
    try testing.expect(inbox.pop() == null);
}

test "Inbox: popIf with always-true predicate behaves like pop" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit();

    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "a") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "b") });
    }

    {
        const m = inbox.popIf(testAlwaysTrue).?;
        defer m.deinit();
        try testing.expectEqual("a", m.payload.ping);
    }
    {
        const m = inbox.popIf(testAlwaysTrue).?;
        defer m.deinit();
        try testing.expectEqual("b", m.payload.ping);
    }
    try testing.expect(inbox.popIf(testAlwaysTrue) == null);
}

test "Inbox: popIf cherry-picks middle, preserves order of remainder" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit();

    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .disconnect = null });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "middle") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .disconnect = error.PeerClosed });
    }

    // testIsPing skips the disconnect at the head and picks the middle.
    {
        const m = inbox.popIf(testIsPing).?;
        defer m.deinit();
        try testing.expectEqual("middle", m.payload.ping);
    }

    // Remaining two disconnects pop in original order.
    {
        const m = inbox.pop().?;
        defer m.deinit();
        try testing.expect(m.payload.disconnect == null);
    }
    {
        const m = inbox.pop().?;
        defer m.deinit();
        try testing.expect(m.payload.disconnect.? == error.PeerClosed);
    }
    try testing.expect(inbox.pop() == null);
}

test "Inbox: popIf picks first match in FIFO order" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit();

    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "first") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .disconnect = null });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "second") });
    }

    const m = inbox.popIf(testIsPing).?;
    defer m.deinit();
    try testing.expectEqual("first", m.payload.ping);
}

test "Inbox: popIf removes tail without breaking the next push" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit();

    {
        const arena = try arena_pool.acquire(.tiny, "popif tail test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "first") });
    }
    {
        const arena = try arena_pool.acquire(.tiny, "popif tail test");
        inbox.push(arena, .{ .disconnect = null });
    }

    const removed = inbox.popIf(testIsDisconnect).?;
    removed.deinit();

    // This append must follow `first`, not the detached former tail.
    {
        const arena = try arena_pool.acquire(.tiny, "popif tail test");
        inbox.push(arena, .{ .ping = try arena.dupe(u8, "second") });
    }

    {
        const msg = inbox.pop().?;
        defer msg.deinit();
        try testing.expectEqual("first", msg.payload.ping);
    }
    {
        const msg = inbox.pop().?;
        defer msg.deinit();
        try testing.expectEqual("second", msg.payload.ping);
    }
    try testing.expect(inbox.pop() == null);
}

test "Inbox: teardown count tracks queued control frames and CDP commands" {
    const arena_pool = &testing.test_app.arena_pool;
    var inbox = Inbox{};
    defer inbox.deinit();

    try testing.expect(!inbox.hasTeardown());

    inline for ([_][]const u8{
        "Runtime.evaluate",
        "Target.closeTarget",
        "Page.close",
    }) |method| {
        const arena = try arena_pool.acquire(.tiny, "teardown count test");
        inbox.push(arena, .{ .cdp = .{
            .raw = try arena.dupe(u8, "{}"),
            .input = .{ .method = method },
        } });
    }
    try testing.expect(inbox.hasTeardown());

    // The ordinary command at the head is not counted.
    {
        const msg = inbox.pop().?;
        defer msg.deinit();
        try testing.expectEqual("Runtime.evaluate", msg.payload.cdp.input.method);
    }
    try testing.expect(inbox.hasTeardown());

    // Removing one of two teardown commands keeps the flag set.
    {
        const msg = inbox.pop().?;
        defer msg.deinit();
        try testing.expectEqual("Target.closeTarget", msg.payload.cdp.input.method);
    }
    try testing.expect(inbox.hasTeardown());

    {
        const msg = inbox.pop().?;
        defer msg.deinit();
        try testing.expectEqual("Page.close", msg.payload.cdp.input.method);
    }
    try testing.expect(!inbox.hasTeardown());
}

test "Inbox: teardown classification preserves sync-wait behavior" {
    try testing.expect(isTeardown(.close));
    try testing.expect(isTeardown(.{ .disconnect = null }));
    try testing.expect(!isTeardown(.{ .ping = "" }));

    var raw: [0]u8 = .{};
    inline for ([_]struct { method: []const u8, expected: bool }{
        .{ .method = "Target.closeTarget", .expected = true },
        .{ .method = "Target.disposeBrowserContext", .expected = true },
        .{ .method = "Page.close", .expected = true },
        .{ .method = "Runtime.evaluate", .expected = false },
    }) |case| {
        try testing.expectEqual(case.expected, isTeardown(.{ .cdp = .{
            .raw = &raw,
            .input = .{ .method = case.method },
        } }));
    }
}
