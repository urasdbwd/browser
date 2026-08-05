// Copyright (C) 2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

//! Bounded HTTP transport for client-side visual rendering.
//!
//! Connection threads only parse HTTP/WebSocket traffic and encode responses.
//! The worker creates and owns one V8 isolate on the first render/live job.
//! One-shot renders use a fresh Session; the live endpoint keeps one Session
//! alive between commands. Both return
//! script-free DOM snapshots for client.js to lay out and paint in a real browser.

const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const ResponseBuffer = @import("../mcp/ResponseBuffer.zig");
const Compression = @import("Compression.zig");
const LiveSession = @import("LiveSession.zig");
const sys_net = @import("../sys/net.zig");
const WS = @import("../network/WS.zig");

const HttpServer = @This();
const posix = std.posix;
const ns_per_ms = std.time.ns_per_ms;

const worker_stack_size = 4 * 1024 * 1024;
// Connection threads compress the response on their own stack, and
// std.compress.flate's allocation-free encoder is the largest frame by far.
// Derive the budget from the encoder instead of guessing at it: the OS commits
// only touched stack pages, so the headroom is free, and a std-side size change
// can no longer silently push this back over the guard page.
// pthread_attr_setstacksize rejects a size that is not a whole number of pages,
// so round up rather than hand back an unspawnable thread.
const connection_stack_size = std.mem.alignForward(
    usize,
    512 * 1024 + Compression.gzip_stack_bytes,
    64 * 1024,
);
const worker_retained_arena_bytes = 64 * 1024;
const live_socket_timeout_ms = 5 * 60 * 1000;
const live_ticket_ttl_ms = 30_000;

const client_js = @embedFile("client.js");
const client_etag = blk: {
    @setEvalBranchQuota(100_000);
    break :blk std.fmt.comptimePrint("W/\"{x}\"", .{std.hash.Wyhash.hash(0, client_js)});
};
const client_cache_control = "public,max-age=0,must-revalidate";

const LiveTickets = struct {
    mutex: std.Io.Mutex = .init,
    entries: []Entry,

    const Entry = struct {
        value: [32]u8 = undefined,
        issued: std.Io.Timestamp = .zero,
        valid: bool = false,
    };

    fn init(allocator: std.mem.Allocator, capacity: usize) !LiveTickets {
        std.debug.assert(capacity > 0);
        const entries = try allocator.alloc(Entry, capacity);
        @memset(entries, .{});
        return .{ .entries = entries };
    }

    fn deinit(self: *LiveTickets, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    fn issue(self: *LiveTickets) ![32]u8 {
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(lp.io, &random);
        const value = std.fmt.bytesToHex(random, .lower);
        self.insertAt(value, .now(lp.io, .boot));
        return value;
    }

    fn insertAt(self: *LiveTickets, value: [32]u8, issued: std.Io.Timestamp) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);

        var target = &self.entries[0];
        for (self.entries) |*entry| {
            if (!entry.valid or expired(entry.*, issued)) {
                target = entry;
                break;
            }
            if (entry.issued.nanoseconds < target.issued.nanoseconds) target = entry;
        }
        target.* = .{ .value = value, .issued = issued, .valid = true };
    }

    fn consume(self: *LiveTickets, candidate: []const u8) bool {
        return self.consumeAt(candidate, .now(lp.io, .boot));
    }

    fn consumeAt(self: *LiveTickets, candidate: []const u8, now: std.Io.Timestamp) bool {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);

        for (self.entries) |*entry| {
            if (!entry.valid) continue;
            if (expired(entry.*, now)) {
                entry.valid = false;
                continue;
            }
            if (!tokenEqual(candidate, &entry.value)) continue;
            entry.valid = false;
            return true;
        }
        return false;
    }

    fn expired(entry: Entry, now: std.Io.Timestamp) bool {
        return entry.issued.durationTo(now).toMilliseconds() > live_ticket_ttl_ms;
    }
};

const Result = enum {
    ok,
    bad_request,
    live_session_closed,
    live_session_active,
    node_not_found,
    stale_target,
    timeout,
    navigation_failed,
    response_too_large,
    shutting_down,
    internal_error,

    fn status(self: Result) std.http.Status {
        return switch (self) {
            .ok => .ok,
            .bad_request => .bad_request,
            .live_session_closed => .not_found,
            .live_session_active => .conflict,
            .node_not_found => .not_found,
            .stale_target => .conflict,
            .timeout => .gateway_timeout,
            .navigation_failed => .bad_gateway,
            .response_too_large => .payload_too_large,
            .shutting_down => .service_unavailable,
            .internal_error => .internal_server_error,
        };
    }

    fn body(self: Result) []const u8 {
        return switch (self) {
            .ok => "",
            .bad_request => "{\"error\":\"invalid render request\"}\n",
            .live_session_closed => "{\"error\":\"live session is not active\"}\n",
            .live_session_active => "{\"error\":\"a live session owns the browser\"}\n",
            .node_not_found => "{\"error\":\"live target was not found\"}\n",
            .stale_target => "{\"error\":\"live target is stale\"}\n",
            .timeout => "{\"error\":\"render deadline exceeded\"}\n",
            .navigation_failed => "{\"error\":\"page navigation failed\"}\n",
            .response_too_large => "{\"error\":\"render snapshot too large\"}\n",
            .shutting_down => "{\"error\":\"render server shutting down\"}\n",
            .internal_error => "{\"error\":\"render failed\"}\n",
        };
    }
};

const JobKind = enum { render, live, live_close };

const Job = struct {
    kind: JobKind = .render,
    body: []const u8,
    out: *std.Io.Writer,
    response: ?*ResponseBuffer = null,
    deadline: std.Io.Timestamp = .zero,
    owner: u64 = 0,
    live_outcome: LiveSession.Outcome = .{ .id = 0 },
    /// One-shot render: Turnstile outcome tag, null when solving is off.
    turnstile: ?[]const u8 = null,
    result: Result = .ok,
    done: std.Io.Event = .unset,
    next: ?*Job = null,
};

// Two intrusive lists behind one mutex and one condvar: renders, which any
// worker may take, and live commands, which only the live worker may take
// (it is the one holding that session's Session and V8 context). Sharing the
// condvar is what keeps this a blocking queue rather than a poll.
const Queue = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    head: ?*Job = null,
    tail: ?*Job = null,
    live_head: ?*Job = null,
    live_tail: ?*Job = null,
    closed: std.atomic.Value(bool) = .init(false),

    // Which lists a given pop is allowed to drain.
    const Take = enum {
        render_only,
        // Live jobs first: a queued live command must not sit behind a render.
        any,
        live_only,
    };

    fn push(self: *Queue, job: *Job) bool {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self.closed.load(.acquire)) return false;
        job.next = null;
        if (job.kind == .render) {
            if (self.tail) |tail| tail.next = job else self.head = job;
            self.tail = job;
        } else {
            if (self.live_tail) |tail| tail.next = job else self.live_head = job;
            self.live_tail = job;
        }
        // Broadcast, not signal: the one worker allowed to take this job may
        // not be the one a signal would wake.
        self.cond.broadcast(lp.io);
        return true;
    }

    fn pop(self: *Queue, take: Take) ?*Job {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        while (self.peek(take) == null and !self.closed.load(.acquire)) {
            self.cond.waitUncancelable(lp.io, &self.mutex);
        }
        return self.takeHead(take);
    }

    fn tryPop(self: *Queue, take: Take) ?*Job {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        return self.takeHead(take);
    }

    fn popFor(self: *Queue, take: Take, timeout_ms: u64) ?*Job {
        return self.popForWaiting(take, timeout_ms, null);
    }

    fn popForWaiting(self: *Queue, take: Take, timeout_ms: u64, waiting: ?*std.Io.Event) ?*Job {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self.peek(take) == null and timeout_ms > 0 and !self.closed.load(.acquire)) {
            if (waiting) |event| event.set(lp.io);
            lp.timedWait(&self.cond, &self.mutex, timeout_ms * ns_per_ms) catch {};
        }
        return self.takeHead(take);
    }

    fn peek(self: *const Queue, take: Take) ?*Job {
        return switch (take) {
            .render_only => self.head,
            .any => self.live_head orelse self.head,
            .live_only => self.live_head,
        };
    }

    fn takeHead(self: *Queue, take: Take) ?*Job {
        const job = self.peek(take) orelse return null;
        if (job.kind == .render) {
            self.head = job.next;
            if (self.head == null) self.tail = null;
        } else {
            self.live_head = job.next;
            if (self.live_head == null) self.live_tail = null;
        }
        return job;
    }

    fn closedAndEmpty(self: *Queue) bool {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        return self.closed.load(.acquire) and self.head == null and self.live_head == null;
    }

    fn close(self: *Queue) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.closed.store(true, .release);
        self.cond.broadcast(lp.io);
    }
};

allocator: std.mem.Allocator,
app: *App,
max_connections: u32,
max_request_size: usize,
max_response_size: usize,
max_wait_ms: u32,
client_timeout_ms: u32,
cors_origin: ?[]const u8,
auth_token: ?[]const u8,
live_tickets: LiveTickets,

queue: Queue = .{},
active_conns: std.atomic.Value(u32) = .init(0),
conn_mutex: std.Io.Mutex = .init,
conns: std.ArrayList(posix.socket_t) = .empty,

// One thread per worker, each owning its own V8 isolate. Worker 0 is the
// live worker: a live session pins the Session and context it was opened on,
// so its commands must come back to the same thread.
worker_threads: []std.Thread = &.{},
browser_mutex: std.Io.Mutex = .init,
active_browsers: []?*lp.Browser = &.{},

pub fn init(allocator: std.mem.Allocator, app: *App) !*HttpServer {
    const self = try allocator.create(HttpServer);
    errdefer allocator.destroy(self);
    const max_connections = app.config.maxConnections();
    self.* = .{
        .allocator = allocator,
        .app = app,
        .max_connections = max_connections,
        .max_request_size = app.config.renderMaxRequestSize(),
        .max_response_size = app.config.renderMaxResponseSize(),
        .max_wait_ms = app.config.renderMaxWaitMs(),
        .client_timeout_ms = app.config.renderClientTimeoutMs(),
        .cors_origin = app.config.renderCorsOrigin(),
        .auth_token = app.config.renderAuthToken(),
        .live_tickets = try .init(allocator, max_connections),
    };
    errdefer self.live_tickets.deinit(allocator);
    if (self.auth_token) |token| {
        if (token.len < 16) return error.WeakAuthToken;
    }
    errdefer self.conns.deinit(allocator);
    try self.conns.ensureTotalCapacity(allocator, self.max_connections);

    const worker_count = app.config.renderWorkers();
    self.active_browsers = try allocator.alloc(?*lp.Browser, worker_count);
    errdefer allocator.free(self.active_browsers);
    @memset(self.active_browsers, null);

    self.worker_threads = try allocator.alloc(std.Thread, worker_count);
    errdefer allocator.free(self.worker_threads);

    var spawned: usize = 0;
    errdefer {
        // Unwind a partial spawn: close the queue so the started workers
        // fall out of their wait, then join them.
        self.queue.close();
        for (self.worker_threads[0..spawned]) |thread| thread.join();
    }
    while (spawned < worker_count) : (spawned += 1) {
        self.worker_threads[spawned] = try std.Thread.spawn(
            .{ .stack_size = worker_stack_size },
            worker,
            .{ self, spawned },
        );
    }
    lp.log.note(.app, "client render workers", .{ .count = worker_count });
    return self;
}

pub fn deinit(self: *HttpServer) void {
    self.queue.close();
    self.terminateBrowser();
    {
        self.conn_mutex.lockUncancelable(lp.io);
        defer self.conn_mutex.unlock(lp.io);
        for (self.conns.items) |socket| sys_net.shutdown(socket, .both) catch {};
    }
    while (self.active_conns.load(.acquire) > 0) {
        lp.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    for (self.worker_threads) |thread| thread.join();

    self.allocator.free(self.worker_threads);
    self.allocator.free(self.active_browsers);
    self.conns.deinit(self.allocator);
    self.live_tickets.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn run(self: *HttpServer, address: sys_net.IpAddress) !void {
    if (!isLoopback(address) and self.auth_token == null) return error.AuthenticationRequired;
    var bound = address;
    try self.app.network.bind(&bound, self, onAccept);
    lp.log.note(.app, "client render server running", .{ .address = bound });
    self.app.network.run();
}

fn terminateBrowser(self: *HttpServer) void {
    self.browser_mutex.lockUncancelable(lp.io);
    defer self.browser_mutex.unlock(lp.io);
    for (self.active_browsers) |maybe| {
        if (maybe) |browser| browser.env.terminate();
    }
}

fn onAccept(ctx: *anyopaque, socket: posix.socket_t) void {
    const self: *HttpServer = @ptrCast(@alignCast(ctx));
    const flags = sys_net.fcntl(socket, posix.F.GETFL, 0) catch {
        _ = std.c.close(socket);
        return;
    };
    _ = sys_net.fcntl(socket, posix.F.SETFL, flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true }))) catch {
        _ = std.c.close(socket);
        return;
    };
    setSocketTimeout(socket, self.client_timeout_ms) catch {
        _ = std.c.close(socket);
        return;
    };

    if (!acquireConnectionSlot(&self.active_conns, self.max_connections)) {
        _ = std.c.close(socket);
        return;
    }
    {
        self.conn_mutex.lockUncancelable(lp.io);
        defer self.conn_mutex.unlock(lp.io);
        self.conns.appendAssumeCapacity(socket);
    }

    const thread = std.Thread.spawn(.{ .stack_size = connection_stack_size }, handleConn, .{ self, socket }) catch {
        _ = self.active_conns.fetchSub(1, .release);
        self.unregister(socket);
        _ = std.c.close(socket);
        return;
    };
    thread.detach();
}

fn setSocketTimeout(socket: posix.socket_t, timeout_ms: u32) !void {
    try setSocketReceiveTimeout(socket, timeout_ms);
    const timeout = socketTimeout(timeout_ms);
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
}

fn setSocketReceiveTimeout(socket: posix.socket_t, timeout_ms: u32) !void {
    const timeout = socketTimeout(timeout_ms);
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
}

fn socketTimeout(timeout_ms: u32) [@sizeOf(posix.timeval)]u8 {
    return std.mem.toBytes(posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    });
}

fn isLoopback(address: sys_net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| ip6.isLoopBack(),
    };
}

fn acquireConnectionSlot(active: *std.atomic.Value(u32), max: u32) bool {
    var current = active.load(.monotonic);
    while (current < max) {
        current = active.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) orelse return true;
    }
    return false;
}

fn unregister(self: *HttpServer, socket: posix.socket_t) void {
    self.conn_mutex.lockUncancelable(lp.io);
    defer self.conn_mutex.unlock(lp.io);
    for (self.conns.items, 0..) |tracked, i| {
        if (tracked == socket) {
            _ = self.conns.swapRemove(i);
            return;
        }
    }
}

fn worker(self: *HttpServer, index: usize) void {
    // Only worker 0 serves the live endpoint; every other worker is renders
    // only and never sees a live job.
    const is_live_worker = index == 0;
    const solo = self.worker_threads.len == 1;

    var browser: lp.Browser = undefined;
    var browser_initialized = false;
    defer if (browser_initialized) browser.deinit();
    defer {
        self.browser_mutex.lockUncancelable(lp.io);
        self.active_browsers[index] = null;
        self.browser_mutex.unlock(lp.io);
    }

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    var live: ?LiveSession = null;
    defer if (live) |*session| session.deinit();
    while (true) {
        if (browser_initialized and live == null) browser.http_client.heartbeat.disarm();
        const job = job: {
            const take: Queue.Take = if (!is_live_worker)
                .render_only
            else if (live == null)
                .any
            else if (solo)
                // Nobody else can serve renders, so keep taking them and keep
                // answering 409 rather than leaving the client to time out.
                .any
            else
                // A sibling worker will pick renders up; this thread belongs
                // to the live session now.
                .live_only;

            if (live == null) break :job self.queue.pop(take);
            if (self.queue.tryPop(take)) |queued| break :job queued;
            const delay_ms = if (live) |*session| session.pump() else unreachable;
            break :job self.queue.popFor(take, liveWaitMs(delay_ms));
        } orelse {
            if (self.queue.closedAndEmpty()) break;
            continue;
        };
        if (self.queue.closed.load(.acquire)) {
            job.result = .shutting_down;
        } else if (job.kind == .live_close) {
            LiveSession.closeOwner(&live, job.owner);
            job.result = .ok;
        } else if (remainingWaitMs(job.deadline, .now(lp.io, .boot)) != null) process: {
            if (!browser_initialized) {
                const initialized = initialized: {
                    self.browser_mutex.lockUncancelable(lp.io);
                    defer self.browser_mutex.unlock(lp.io);
                    browser.init(self.app, .{}, null) catch |err| {
                        lp.log.err(.app, "client render browser init", .{ .err = err });
                        break :initialized false;
                    };
                    browser_initialized = true;
                    self.active_browsers[index] = &browser;
                    break :initialized true;
                };
                if (!initialized) {
                    job.result = .internal_error;
                    break :process;
                }
            }

            switch (job.kind) {
                .render => render: {
                    // One-shot renders share the browser with the live session.
                    // Tearing an active one down here would let any client on
                    // this port evict another user's session.
                    if (live != null) {
                        job.result = .live_session_active;
                        break :render;
                    }
                    const prepared = prepareRender(self.app.config, arena.allocator(), job) orelse break :render;
                    const render_wait_ms = remainingWaitMs(job.deadline, .now(lp.io, .boot)) orelse {
                        job.result = .timeout;
                        break :render;
                    };
                    processRender(self, &browser, job, prepared, render_wait_ms);
                },
                .live => processLive(self, &browser, &live, arena.allocator(), job),
                .live_close => unreachable,
            }
        } else {
            job.result = .timeout;
        }
        _ = arena.reset(.{ .retain_with_limit = worker_retained_arena_bytes });
        job.done.set(lp.io);
    }
}

fn liveWaitMs(delay_ms: u31) u64 {
    return @max(1, @as(u64, delay_ms));
}

fn jobDeadline(max_wait_ms: u32) std.Io.Timestamp {
    return std.Io.Timestamp.now(lp.io, .boot).addDuration(
        .fromMilliseconds(@intCast(max_wait_ms)),
    );
}

fn remainingWaitMs(deadline: std.Io.Timestamp, now: std.Io.Timestamp) ?u32 {
    const remaining_ns = now.durationTo(deadline).toNanoseconds();
    if (remaining_ns <= 0) return null;
    const rounded_ms = @divTrunc(remaining_ns + ns_per_ms - 1, ns_per_ms);
    return std.math.cast(u32, rounded_ms) orelse std.math.maxInt(u32);
}

fn processLive(
    self: *HttpServer,
    browser: *lp.Browser,
    live: *?LiveSession,
    arena: std.mem.Allocator,
    job: *Job,
) void {
    const command = LiveSession.parseCommand(arena, job.body) catch |err| {
        if (err == error.BadRequest) {
            const Peek = struct { id: u32 = 0 };
            if (std.json.parseFromSliceLeaky(Peek, arena, job.body, .{
                .ignore_unknown_fields = true,
            }) catch null) |peek| {
                job.live_outcome.id = peek.id;
            }
        }
        job.result = if (err == error.InternalError) .internal_error else .bad_request;
        return;
    };
    job.live_outcome.id = command.id;

    job.live_outcome = LiveSession.processParsed(
        live,
        self.app,
        browser,
        arena,
        job.owner,
        command,
        job.deadline,
        job.out,
    ) catch |err| {
        job.result = switch (err) {
            error.BadRequest => .bad_request,
            // An `open` that loses the race is refused because someone else
            // holds the browser, not because this client's session vanished.
            // Only the latter closes the connection.
            error.NotOwner => if (command.type == .open) .live_session_active else .live_session_closed,
            error.NodeNotFound => .node_not_found,
            error.StaleTarget => .stale_target,
            error.Timeout => .timeout,
            error.NavigationFailed => .navigation_failed,
            error.InternalError => .internal_error,
        };
        return;
    };
    job.result = .ok;
}

const RenderRequest = struct {
    url: []const u8,
    wait_ms: u32 = 5_000,
    // Caps only the implicit "let the page settle" wait, which chases `.done`
    // (no macrotasks AND no network) -- a state many real pages never reach,
    // so without a cap every load burns the full wait_ms. Raise it for a page
    // that genuinely hydrates late.
    settle_ms: ?u32 = null,
    wait_until: ?lp.Config.WaitUntil = null,
    wait_selector: ?[]const u8 = null,
    width: u32 = 1280,
    height: u32 = 720,
    direct_resources: LiveSession.DirectResources = .off,
};

const PreparedRender = struct {
    url: [:0]const u8,
    wait_ms: u32,
    settle_ms: ?u32,
    wait_until: ?lp.Config.WaitUntil,
    wait_selector: ?[:0]const u8,
    width: u32,
    height: u32,
    direct_resources: bool,
};

fn prepareRender(
    config: *const lp.Config,
    arena: std.mem.Allocator,
    job: *Job,
) ?PreparedRender {
    const request = std.json.parseFromSliceLeaky(RenderRequest, arena, job.body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        job.result = if (err == error.OutOfMemory) .internal_error else .bad_request;
        return null;
    };
    if (request.url.len == 0 or request.url.len > 8 * 1024 or
        request.width == 0 or request.width > 8192 or request.height == 0 or request.height > 8192)
    {
        job.result = .bad_request;
        return null;
    }
    if (request.wait_selector) |selector| {
        if (selector.len == 0 or selector.len > 1024) {
            job.result = .bad_request;
            return null;
        }
    }

    const canonical = lp.URL.resolveNavigation(arena, request.url, .{}) catch |err| {
        job.result = if (err == error.OutOfMemory) .internal_error else .bad_request;
        return null;
    };
    const protocol = lp.URL.getProtocol(canonical);
    if ((!std.mem.eql(u8, protocol, "http:") and !std.mem.eql(u8, protocol, "https:")) or
        lp.URL.getUsername(canonical).len != 0 or lp.URL.getPassword(canonical).len != 0)
    {
        job.result = .bad_request;
        return null;
    }

    const selector: ?[:0]const u8 = if (request.wait_selector) |value|
        arena.dupeZ(u8, value) catch {
            job.result = .internal_error;
            return null;
        }
    else
        null;
    return .{
        .url = canonical,
        .wait_ms = request.wait_ms,
        .settle_ms = request.settle_ms,
        .wait_until = request.wait_until,
        .wait_selector = selector,
        .width = request.width,
        .height = request.height,
        .direct_resources = request.direct_resources.enabled(config),
    };
}

fn processRender(
    self: *HttpServer,
    browser: *lp.Browser,
    job: *Job,
    request: PreparedRender,
    max_wait_ms: u32,
) void {
    browser.viewport_override = .{ .width = request.width, .height = request.height };

    // `lp.fetch` runs the solve itself when `--solve-captchas` is on (auto = on
    // under `--stealth`), sharing the one wait budget with the page waits. It
    // only writes here when it ran, so the config decides whether we report.
    var turnstile: lp.Turnstile.Result = .no_widget;

    var urls = [_][:0]const u8{request.url};
    lp.fetch(self.app, browser, &urls, .{
        .turnstile = &turnstile,
        .wait_ms = @min(request.wait_ms, max_wait_ms),
        .settle_ms = request.settle_ms,
        .wait_until = request.wait_until,
        .wait_selector = request.wait_selector,
        .dump = .{
            .with_base = true,
            .with_frames = false,
            .strip = .{ .js = true, .meta = true },
            .with_render_csp = true,
            .direct_render_resources = request.direct_resources,
        },
        .dump_mode = .html,
        .writer = job.out,
    }) catch |err| {
        job.result = if (err == error.Timeout)
            .timeout
        else if (err == error.WriteFailed)
            .response_too_large
        else switch (err) {
            error.TypeError, error.InvalidURL => .bad_request,
            error.OutOfMemory => .internal_error,
            else => .navigation_failed,
        };
        return;
    };
    if (self.app.config.solveCaptchas()) {
        job.turnstile = @tagName(turnstile);
        lp.log.info(.app, "render turnstile", .{ .result = job.turnstile });
    }
    job.result = .ok;
}

fn handleConn(self: *HttpServer, socket: posix.socket_t) void {
    defer _ = self.active_conns.fetchSub(1, .release);
    const stream: std.Io.net.Stream = .{ .socket = .{ .handle = socket, .address = .{ .ip4 = .unspecified(0) } } };
    defer stream.close(lp.io);
    defer self.unregister(socket);

    var recv_buf: [64 * 1024]u8 = undefined;
    var send_buf: [8 * 1024]u8 = undefined;
    var stream_reader = stream.reader(lp.io, &recv_buf);
    var stream_writer = stream.writer(lp.io, &send_buf);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var request = http_server.receiveHead() catch return;
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    var out: ResponseBuffer = .init(self.allocator, self.max_response_size);
    defer out.deinit();
    self.serve(&out, arena.allocator(), socket, &request) catch {};
}

fn serve(
    self: *HttpServer,
    out: *ResponseBuffer,
    arena: std.mem.Allocator,
    socket: posix.socket_t,
    request: *std.http.Server.Request,
) !void {
    if (request.head.expect != null) {
        return request.respond("", .{ .status = .expectation_failed, .keep_alive = false });
    }

    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const origin = headerValue(request, "origin");
    const cors_value: ?[]const u8 = if (origin != null)
        self.allowedCorsValue(origin) orelse
            return respondJson(request, .forbidden, "{\"error\":\"origin not allowed\"}\n", null)
    else
        null;

    if (request.head.method == .OPTIONS) {
        return respondPreflight(request, cors_value);
    }

    if (request.head.method == .POST and std.mem.eql(u8, path, "/v1/live-ticket")) {
        if (origin == null or !self.allowedLiveOrigin(origin.?)) {
            return respondJson(request, .forbidden, "{\"error\":\"exact origin required for live view\"}\n", null);
        }
        if (!authorized(request, self.auth_token)) {
            return respondJson(request, .unauthorized, "{\"error\":\"authentication required\"}\n", cors_value);
        }
        const ticket = self.live_tickets.issue() catch
            return respondJson(request, .internal_server_error, "{\"error\":\"ticket generation failed\"}\n", cors_value);
        var response_buf: [64]u8 = undefined;
        const body = try std.fmt.bufPrint(&response_buf, "{{\"ticket\":\"{s}\"}}\n", .{ticket});
        return respondJson(request, .ok, body, cors_value);
    }

    if (request.head.method == .GET and std.mem.eql(u8, path, "/v1/live")) {
        if (origin == null or !self.allowedLiveOrigin(origin.?)) {
            return respondJson(request, .forbidden, "{\"error\":\"exact origin required for live view\"}\n", null);
        }
        const key = switch (request.upgradeRequested()) {
            .websocket => |value| value orelse
                return respondJson(request, .bad_request, "{\"error\":\"missing websocket key\"}\n", cors_value),
            else => return respondJson(request, .bad_request, "{\"error\":\"websocket upgrade required\"}\n", cors_value),
        };
        if (!validWebSocketHandshake(request, key)) {
            return respondJson(request, .bad_request, "{\"error\":\"invalid websocket handshake\"}\n", cors_value);
        }
        const ticket = (queryValue(arena, target, "ticket") catch
            return respondJson(request, .internal_server_error, Result.internal_error.body(), cors_value)) orelse
            return respondJson(request, .unauthorized, "{\"error\":\"live ticket required\"}\n", cors_value);
        if (!self.live_tickets.consume(ticket)) {
            return respondJson(request, .unauthorized, "{\"error\":\"authentication required\"}\n", cors_value);
        }
        const snapshot_encodings = (queryValue(arena, target, "snapshot_encodings") catch
            return respondJson(request, .internal_server_error, Result.internal_error.body(), cors_value));
        const compression_preferences = liveCompressionPreferences(snapshot_encodings);

        try setSocketReceiveTimeout(socket, @max(self.client_timeout_ms, live_socket_timeout_ms));
        var websocket = try request.respondWebSocket(.{ .key = key });
        try websocket.output.flush();
        return self.serveLiveWebSocket(out, &websocket, compression_preferences);
    }

    var negotiator: Compression.Negotiator = .{};
    addAcceptEncodings(request, &negotiator);
    const preferences = negotiator.preferences();

    if ((request.head.method == .GET or request.head.method == .HEAD) and
        std.mem.eql(u8, path, "/lightpanda-renderer.js"))
    {
        if (headerEquals(request, "if-none-match", client_etag)) {
            return respondNotModified(request, cors_value);
        }
        return respondBody(
            request,
            client_js,
            .ok,
            "text/javascript; charset=utf-8",
            client_cache_control,
            client_etag,
            preferences,
            cors_value,
            null,
        );
    }
    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/healthz")) {
        return respondBody(request, "ok\n", .ok, "text/plain; charset=utf-8", "no-store", null, .{}, cors_value, null);
    }
    if (request.head.method != .POST or !std.mem.eql(u8, path, "/v1/render")) {
        return respondJson(request, .not_found, "{\"error\":\"not found\"}\n", cors_value);
    }
    if (!authorized(request, self.auth_token)) {
        return respondJson(request, .unauthorized, "{\"error\":\"authentication required\"}\n", cors_value);
    }
    const content_type = headerValue(request, "content-type") orelse "";
    if (!isJsonContentType(content_type)) {
        return respondJson(request, .unsupported_media_type, "{\"error\":\"application/json required\"}\n", cors_value);
    }

    const content_length = if (request.head.transfer_encoding == .none)
        request.head.content_length
    else
        null;
    var body_buf: [8 * 1024]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buf);
    const body = readRequestBody(arena, body_reader, content_length, self.max_request_size) catch |err| {
        return switch (err) {
            error.OutOfMemory => respondJson(
                request,
                .internal_server_error,
                Result.internal_error.body(),
                cors_value,
            ),
            error.StreamTooLong => respondJson(
                request,
                .payload_too_large,
                "{\"error\":\"request too large\"}\n",
                cors_value,
            ),
            else => err,
        };
    };

    var job: Job = .{
        .body = body,
        .out = &out.writer,
        .response = out,
        .deadline = jobDeadline(self.max_wait_ms),
    };
    if (!self.queue.push(&job)) {
        return respondJson(request, .service_unavailable, Result.shutting_down.body(), cors_value);
    }
    job.done.waitUncancelable(lp.io);

    if (out.failure) |failure| {
        if (failure == .out_of_memory) {
            job.result = .internal_error;
        } else if (job.result == .ok) {
            job.result = .response_too_large;
        }
    }
    if (job.result != .ok) {
        return respondJson(request, job.result.status(), job.result.body(), cors_value);
    }
    return respondBody(
        request,
        out.buffered(),
        .ok,
        "text/html; charset=utf-8",
        "no-store",
        null,
        preferences,
        cors_value,
        job.turnstile,
    );
}

const live_close_internal_error = [_]u8{ 0x88, 0x02, 0x03, 0xf3 }; // 1011

fn readLiveMessage(
    input: *std.Io.Reader,
    reader: *WS.Reader(true),
) !WS.Message {
    while (true) {
        if (try reader.next()) |message| return message;
        reader.compact();

        const dst = reader.readBuf();
        std.debug.assert(dst.len != 0);

        // The HTTP parser may have already read bytes beyond the upgrade
        // request. Drain those before attempting another socket read.
        const buffered = input.buffered();
        if (buffered.len != 0) {
            const n = @min(buffered.len, dst.len);
            @memcpy(dst[0..n], buffered[0..n]);
            input.toss(n);
            reader.len += n;
            continue;
        }

        var vecs: [1][]u8 = .{dst};
        const n = try input.readVec(&vecs);
        reader.len += n;
    }
}

fn liveCloseFrameForError(err: anyerror) ?[]const u8 {
    if (WS.errorReply(err)) |frame| return frame;
    if (err == error.OutOfMemory) return &live_close_internal_error;
    return null;
}

fn writeRawWebSocketFrame(
    websocket: *std.http.Server.WebSocket,
    frame: []const u8,
) std.Io.Writer.Error!void {
    try websocket.output.writeAll(frame);
    try websocket.output.flush();
}

fn serveLiveWebSocket(
    self: *HttpServer,
    out: *ResponseBuffer,
    websocket: *std.http.Server.WebSocket,
    compression_preferences: Compression.Preferences,
) !void {
    var encoded: ResponseBuffer = .init(self.allocator, self.max_response_size);
    defer encoded.deinit();

    var reader = WS.Reader(true).init(
        self.allocator,
        self.max_request_size,
    ) catch |err| {
        if (liveCloseFrameForError(err)) |frame| {
            writeRawWebSocketFrame(websocket, frame) catch {};
            return;
        }
        return err;
    };
    defer reader.deinit();

    var owner: u64 = undefined;
    std.Io.random(lp.io, std.mem.asBytes(&owner));
    if (owner == 0) owner = 1;
    // The last snapshot this connection transmitted. It is the base every delta
    // is measured against, and comparing against it gives the identical-frame
    // check for free. Per connection, because the client's copy is too.
    var base: std.ArrayList(u8) = .empty;
    defer base.deinit(self.allocator);

    defer {
        var close_job: Job = .{
            .kind = .live_close,
            .body = "",
            .out = &out.writer,
            .owner = owner,
        };
        if (self.queue.push(&close_job)) close_job.done.waitUncancelable(lp.io);
    }

    while (true) {
        const message = readLiveMessage(websocket.input, &reader) catch |err| {
            if (liveCloseFrameForError(err)) |frame| {
                writeRawWebSocketFrame(websocket, frame) catch {};
                return;
            }
            switch (err) {
                error.EndOfStream, error.ReadFailed => return,
                else => return err,
            }
        };
        defer if (message.cleanup_fragment) reader.cleanup();

        switch (message.type) {
            .ping => {
                try websocket.writeMessage(message.data, .pong);
                continue;
            },
            .pong => continue,
            .close => {
                try websocket.writeMessage(message.data, .connection_close);
                return;
            },
            .binary => {
                try websocket.writeMessage(
                    "{\"id\":0,\"ok\":false,\"error\":\"invalid live command\"}",
                    .text,
                );
                continue;
            },
            .text => {},
        }

        out.reset(worker_retained_arena_bytes);
        var job: Job = .{
            .kind = .live,
            .body = message.data,
            .out = &out.writer,
            .response = out,
            .deadline = jobDeadline(self.max_wait_ms),
            .owner = owner,
        };
        if (!self.queue.push(&job)) {
            try websocket.writeMessage(
                "{\"id\":0,\"ok\":false,\"error\":\"render server shutting down\"}",
                .text,
            );
            return;
        }
        job.done.waitUncancelable(lp.io);

        if (out.failure) |failure| {
            if (failure == .out_of_memory) {
                job.result = .internal_error;
            } else if (job.result == .ok and job.live_outcome.snapshot) {
                job.result = .response_too_large;
            }
        }
        var delta: ?SnapshotDelta = null;
        if (job.result == .ok and job.live_outcome.snapshot) {
            const snapshot = out.buffered();
            if (std.mem.eql(u8, base.items, snapshot)) {
                job.live_outcome.snapshot = false;
                job.live_outcome.target_version = null;
            } else {
                // Measured against the base the client still holds, before the
                // base advances to what we are about to send.
                delta = snapshotDelta(base.items, snapshot);
                base.clearRetainingCapacity();
                // A base we could not keep only costs the next frame its delta:
                // an empty base yields no delta, so a full snapshot resyncs us.
                base.appendSlice(self.allocator, snapshot) catch
                    base.clearRetainingCapacity();
            }
        }
        try sendLiveResult(
            websocket,
            &job,
            out.buffered(),
            delta,
            compression_preferences,
            &encoded,
        );
        out.reset(worker_retained_arena_bytes);
        if (job.result == .live_session_closed) {
            websocket.writeMessage("", .connection_close) catch {};
            return;
        }
    }
}

const EncodedLiveSnapshot = struct {
    bytes: []const u8,
    encoding: Compression.Encoding,
};

const SnapshotDelta = struct {
    prefix: usize,
    suffix: usize,
    base_bytes: usize,
    body: []const u8,
};

/// Shared head, shared tail, changed middle, measured against the last snapshot
/// this connection transmitted. A live document is re-serialized in full on
/// every update, so without this an animating page pays its whole document size
/// per frame for a handful of changed attributes.
///
/// Returns null when a full snapshot is the better wire, which also covers the
/// first frame of every connection.
// ponytail: one window, so edits at both ends of a document fall back to the
// full snapshot. Upgrade path if that shows up in real traffic: a block-hash
// rolling diff emitting several windows over the same three wire fields.
fn snapshotDelta(base: []const u8, snapshot: []const u8) ?SnapshotDelta {
    if (base.len == 0 or snapshot.len == 0) return null;
    const limit = @min(base.len, snapshot.len);
    var prefix: usize = 0;
    while (prefix < limit and base[prefix] == snapshot[prefix]) prefix += 1;
    var suffix: usize = 0;
    while (suffix < limit - prefix and
        base[base.len - 1 - suffix] == snapshot[snapshot.len - 1 - suffix]) suffix += 1;
    const body = snapshot[prefix .. snapshot.len - suffix];
    // Only worth the extra client step when it saves most of the document.
    if (body.len * 2 >= snapshot.len) return null;
    return .{
        .prefix = prefix,
        .suffix = suffix,
        .base_bytes = base.len,
        .body = body,
    };
}

fn encodeLiveSnapshot(
    snapshot: []const u8,
    preferences: Compression.Preferences,
    encoded: *ResponseBuffer,
) EncodedLiveSnapshot {
    encoded.reset(worker_retained_arena_bytes);
    var compression = Compression.Stream.init(preferences, snapshot) orelse
        return .{ .bytes = snapshot, .encoding = .identity };
    defer compression.deinit();

    if (compression.encoding == .identity) {
        return .{ .bytes = snapshot, .encoding = .identity };
    }
    compression.writeAll(snapshot, &encoded.writer) catch {
        encoded.reset(worker_retained_arena_bytes);
        return .{ .bytes = snapshot, .encoding = .identity };
    };
    const compressed = encoded.buffered();
    if (encoded.failure != null or compressed.len >= snapshot.len) {
        encoded.reset(worker_retained_arena_bytes);
        return .{ .bytes = snapshot, .encoding = .identity };
    }
    return .{ .bytes = compressed, .encoding = compression.encoding };
}

fn sendLiveResult(
    websocket: *std.http.Server.WebSocket,
    job: *const Job,
    snapshot: []const u8,
    delta: ?SnapshotDelta,
    compression_preferences: Compression.Preferences,
    encoded_buffer: *ResponseBuffer,
) !void {
    // A delta ships only its changed middle; the client rebuilds the document
    // from the frame it already holds.
    const body = if (delta) |value| value.body else snapshot;
    const payload = if (job.result == .ok and job.live_outcome.snapshot)
        encodeLiveSnapshot(body, compression_preferences, encoded_buffer)
    else
        EncodedLiveSnapshot{ .bytes = &.{}, .encoding = .identity };

    var buffer: [640]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeLiveMetadata(job, payload.encoding, body.len, delta, &writer);
    try websocket.writeMessage(writer.buffered(), .text);
    if (job.result == .ok and job.live_outcome.snapshot) {
        try websocket.writeMessage(payload.bytes, .binary);
    }
}

const LiveDeltaMetadata = struct {
    prefix: usize,
    suffix: usize,
    base_bytes: usize,
};

fn writeLiveMetadata(
    job: *const Job,
    encoding: Compression.Encoding,
    snapshot_bytes: usize,
    delta: ?SnapshotDelta,
    writer: *std.Io.Writer,
) !void {
    if (job.result == .ok) {
        const has_snapshot = job.live_outcome.snapshot;
        const version_storage = job.live_outcome.target_version;
        const target_version: ?[]const u8 = if (version_storage) |*version| version else null;
        const snapshot_encoding: ?[]const u8 = if (has_snapshot) @tagName(encoding) else null;
        // `base_bytes` lets the client prove it is patching the document the
        // server measured against; a desync becomes a loud protocol error
        // instead of a silently corrupted page.
        const snapshot_delta: ?LiveDeltaMetadata = if (has_snapshot) if (delta) |value| .{
            .prefix = value.prefix,
            .suffix = value.suffix,
            .base_bytes = value.base_bytes,
        } else null else null;
        try std.json.Stringify.value(.{
            .id = job.live_outcome.id,
            .ok = true,
            .snapshot = has_snapshot,
            .closed = job.live_outcome.closed,
            .warning = job.live_outcome.warning,
            .target_version = target_version,
            .snapshot_encoding = snapshot_encoding,
            .snapshot_bytes = if (has_snapshot) snapshot_bytes else 0,
            .snapshot_delta = snapshot_delta,
            .can_go_back = job.live_outcome.can_go_back,
            .can_go_forward = job.live_outcome.can_go_forward,
            // null unless --solve-captchas is active. Lets a client tell a real
            // page from a snapshot of an unsolved challenge.
            .turnstile = job.live_outcome.turnstile,
        }, .{}, writer);
    } else {
        try std.json.Stringify.value(.{
            .id = job.live_outcome.id,
            .ok = false,
            .@"error" = liveError(job.result),
        }, .{}, writer);
    }
}

fn liveError(result: Result) []const u8 {
    return switch (result) {
        .ok => "",
        .bad_request => "invalid live command",
        .live_session_closed => "live session is not active",
        .live_session_active => "a live session owns the browser",
        .node_not_found => "live target was not found",
        .stale_target => "live target is stale",
        .timeout => "live command deadline exceeded",
        .navigation_failed => "page navigation failed",
        .response_too_large => "render snapshot too large",
        .shutting_down => "render server shutting down",
        .internal_error => "live command failed",
    };
}

fn isJsonContentType(raw: []const u8) bool {
    const value = std.mem.trimStart(u8, raw, &std.ascii.whitespace);
    const mime = "application/json";
    if (value.len < mime.len or !std.ascii.eqlIgnoreCase(value[0..mime.len], mime)) return false;
    return value.len == mime.len or value[mime.len] == ';' or std.ascii.isWhitespace(value[mime.len]);
}

fn respondBody(
    request: *std.http.Server.Request,
    body: []const u8,
    status: std.http.Status,
    content_type: []const u8,
    cache_control: []const u8,
    etag: ?[]const u8,
    preferences: Compression.Preferences,
    cors_value: ?[]const u8,
    turnstile: ?[]const u8,
) !void {
    var compression = Compression.Stream.init(preferences, body) orelse
        return respondNotAcceptable(request, cors_value);
    defer compression.deinit();

    var headers: [10]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "content-type", .value = content_type };
    count += 1;
    headers[count] = .{ .name = "cache-control", .value = cache_control };
    count += 1;
    headers[count] = .{ .name = "x-content-type-options", .value = "nosniff" };
    count += 1;
    headers[count] = .{ .name = "vary", .value = "accept-encoding, origin" };
    count += 1;
    if (etag) |value| {
        headers[count] = .{ .name = "etag", .value = value };
        count += 1;
    }
    if (compression.encoding.contentEncoding()) |encoding| {
        headers[count] = .{ .name = "content-encoding", .value = encoding };
        count += 1;
    }
    if (cors_value) |value| {
        headers[count] = .{ .name = "access-control-allow-origin", .value = value };
        count += 1;
        headers[count] = .{ .name = "cross-origin-resource-policy", .value = "cross-origin" };
        count += 1;
    }
    // A snapshot of an unsolved challenge page is otherwise indistinguishable
    // from the real thing. The body is HTML, so a header is the only slot.
    if (turnstile) |value| {
        headers[count] = .{ .name = "x-lp-turnstile", .value = value };
        count += 1;
        // ponytail: not in access-control-expose-headers — the render API is
        // server-to-server. Add it when a browser client needs to read this.
    }

    if (compression.encoding == .identity) {
        return request.respond(body, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = headers[0..count],
        });
    }

    var response_buf: [8 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buf, .{
        .respond_options = .{
            .status = status,
            .keep_alive = false,
            .extra_headers = headers[0..count],
        },
    });
    try compression.writeAll(body, &response.writer);
    try response.end();
}

fn respondNotAcceptable(request: *std.http.Server.Request, cors_value: ?[]const u8) !void {
    var headers: [4]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "cache-control", .value = "no-store" };
    count += 1;
    headers[count] = .{ .name = "vary", .value = "accept-encoding, origin" };
    count += 1;
    if (cors_value) |value| {
        headers[count] = .{ .name = "access-control-allow-origin", .value = value };
        count += 1;
        headers[count] = .{ .name = "cross-origin-resource-policy", .value = "cross-origin" };
        count += 1;
    }
    return request.respond("", .{
        .status = .not_acceptable,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    });
}

fn respondNotModified(request: *std.http.Server.Request, cors_value: ?[]const u8) !void {
    var headers: [6]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "etag", .value = client_etag };
    count += 1;
    headers[count] = .{ .name = "cache-control", .value = client_cache_control };
    count += 1;
    headers[count] = .{ .name = "vary", .value = "accept-encoding, origin" };
    count += 1;
    headers[count] = .{ .name = "x-content-type-options", .value = "nosniff" };
    count += 1;
    if (cors_value) |value| {
        headers[count] = .{ .name = "access-control-allow-origin", .value = value };
        count += 1;
        headers[count] = .{ .name = "cross-origin-resource-policy", .value = "cross-origin" };
        count += 1;
    }
    return request.respond("", .{
        .status = .not_modified,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    });
}

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8, cors_value: ?[]const u8) !void {
    var headers: [4]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "content-type", .value = "application/json; charset=utf-8" };
    count += 1;
    headers[count] = .{ .name = "cache-control", .value = "no-store" };
    count += 1;
    // The body is identical for every origin but the Allow-Origin header is
    // not; every other responder already declares this.
    headers[count] = .{ .name = "vary", .value = "origin" };
    count += 1;
    if (cors_value) |value| {
        headers[count] = .{ .name = "access-control-allow-origin", .value = value };
        count += 1;
    }
    return request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    });
}

fn respondPreflight(request: *std.http.Server.Request, cors_value: ?[]const u8) !void {
    const value = cors_value orelse return respondJson(
        request,
        .forbidden,
        "{\"error\":\"origin not allowed\"}\n",
        null,
    );
    const headers = [_]std.http.Header{
        .{ .name = "access-control-allow-origin", .value = value },
        .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
        .{ .name = "access-control-allow-headers", .value = "content-type, authorization" },
        .{ .name = "access-control-max-age", .value = "86400" },
        .{ .name = "vary", .value = "origin" },
    };
    return request.respond("", .{
        .status = .no_content,
        .keep_alive = false,
        .extra_headers = &headers,
    });
}

fn authorized(request: *std.http.Server.Request, expected: ?[]const u8) bool {
    const token = expected orelse return true;
    const value = headerValue(request, "authorization") orelse return false;
    const prefix = "Bearer ";
    if (!std.ascii.startsWithIgnoreCase(value, prefix)) return false;
    return tokenEqual(value[prefix.len..], token);
}

fn tokenEqual(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    var difference: u8 = 0;
    for (actual, expected) |a, b| difference |= a ^ b;
    return difference == 0;
}

fn validWebSocketHandshake(request: *std.http.Server.Request, key: []const u8) bool {
    if (request.head.version != .@"HTTP/1.1") return false;
    if (!headerHasToken(request, "connection", "upgrade")) return false;
    const version = headerValue(request, "sec-websocket-version") orelse return false;
    if (!std.mem.eql(u8, version, "13")) return false;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(key) catch return false;
    if (decoded_len != 16) return false;
    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, key) catch return false;
    return true;
}

fn liveCompressionPreferences(encodings: ?[]const u8) Compression.Preferences {
    var negotiator: Compression.Negotiator = .{};
    if (encodings) |value| negotiator.add(value);
    return negotiator.preferences();
}

fn queryValue(
    arena: std.mem.Allocator,
    target: []const u8,
    name: []const u8,
) error{OutOfMemory}!?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var fields = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (fields.next()) |field| {
        const separator = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (!std.mem.eql(u8, field[0..separator], name)) continue;
        const decoded = try arena.dupe(u8, field[separator + 1 ..]);
        for (decoded) |*byte| {
            if (byte.* == '+') byte.* = ' ';
        }
        return std.Uri.percentDecodeInPlace(decoded);
    }
    return null;
}

fn allowedCorsValue(self: *const HttpServer, origin: ?[]const u8) ?[]const u8 {
    const requested = origin orelse return null;
    const allowed = self.cors_origin orelse return null;
    if (std.mem.eql(u8, allowed, "*") or std.mem.eql(u8, allowed, requested)) return allowed;
    return null;
}

fn allowedLiveOrigin(self: *const HttpServer, requested: []const u8) bool {
    const allowed = self.cors_origin orelse return false;
    return !std.mem.eql(u8, allowed, "*") and std.mem.eql(u8, allowed, requested);
}

fn addAcceptEncodings(request: *std.http.Server.Request, negotiator: *Compression.Negotiator) void {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) negotiator.add(header.value);
    }
}

fn headerValue(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn headerEquals(request: *std.http.Server.Request, name: []const u8, expected: []const u8) bool {
    const value = headerValue(request, name) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn headerHasToken(request: *std.http.Server.Request, name: []const u8, expected: []const u8) bool {
    const value = headerValue(request, name) orelse return false;
    var tokens = std.mem.tokenizeAny(u8, value, ", \t");
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, expected)) return true;
    }
    return false;
}

fn readRequestBody(
    arena: std.mem.Allocator,
    reader: *std.Io.Reader,
    content_length: ?u64,
    max_request_size: usize,
) ![]const u8 {
    if (content_length) |len64| {
        const len = std.math.cast(usize, len64) orelse return error.StreamTooLong;
        if (len > max_request_size) return error.StreamTooLong;
        if (len <= reader.buffer.len) return try reader.take(len);
        const body = try arena.alloc(u8, len);
        try reader.readSliceAll(body);
        return body;
    }
    return reader.allocRemaining(arena, .limited(max_request_size));
}

const testing = @import("../testing.zig");

test "render server: connection slots are bounded" {
    var active: std.atomic.Value(u32) = .init(0);
    try std.testing.expect(acquireConnectionSlot(&active, 2));
    try std.testing.expect(acquireConnectionSlot(&active, 2));
    try std.testing.expect(!acquireConnectionSlot(&active, 2));
}

test "render server: live waits never spin on a zero deadline" {
    try std.testing.expectEqual(@as(u64, 1), liveWaitMs(0));
    try std.testing.expectEqual(@as(u64, 1), liveWaitMs(1));
    try std.testing.expectEqual(@as(u64, 250), liveWaitMs(250));
}

test "render server: live metadata carries target version and stale error" {
    try std.testing.expectEqual(std.http.Status.conflict, Result.stale_target.status());
    // A one-shot render must not be able to evict another user's live session.
    try std.testing.expectEqual(std.http.Status.conflict, Result.live_session_active.status());
    try std.testing.expectEqualStrings(
        "{\"error\":\"live target is stale\"}\n",
        Result.stale_target.body(),
    );

    var sink_buffer: [1]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);
    const version: [16]u8 = "0123456789abcdef".*;
    var job: Job = .{
        .body = "",
        .out = &sink,
        .live_outcome = .{
            .id = 7,
            .snapshot = true,
            .target_version = version,
        },
    };

    var metadata_buffer: [512]u8 = undefined;
    var metadata: std.Io.Writer = .fixed(&metadata_buffer);
    try writeLiveMetadata(&job, .br, 4_096, null, &metadata);
    try std.testing.expectEqualStrings(
        "{\"id\":7,\"ok\":true,\"snapshot\":true,\"closed\":false,\"warning\":null,\"target_version\":\"0123456789abcdef\",\"snapshot_encoding\":\"br\",\"snapshot_bytes\":4096,\"snapshot_delta\":null,\"can_go_back\":false,\"can_go_forward\":false,\"turnstile\":null}",
        metadata.buffered(),
    );

    job.live_outcome = .{ .id = 7 };
    metadata = .fixed(&metadata_buffer);
    try writeLiveMetadata(&job, .identity, 0, null, &metadata);
    try std.testing.expectEqualStrings(
        "{\"id\":7,\"ok\":true,\"snapshot\":false,\"closed\":false,\"warning\":null,\"target_version\":null,\"snapshot_encoding\":null,\"snapshot_bytes\":0,\"snapshot_delta\":null,\"can_go_back\":false,\"can_go_forward\":false,\"turnstile\":null}",
        metadata.buffered(),
    );

    job.result = .stale_target;
    job.live_outcome = .{ .id = 8 };
    metadata = .fixed(&metadata_buffer);
    try writeLiveMetadata(&job, .identity, 0, null, &metadata);
    try std.testing.expectEqualStrings(
        "{\"id\":8,\"ok\":false,\"error\":\"live target is stale\"}",
        metadata.buffered(),
    );

    job.result = .response_too_large;
    job.live_outcome = .{ .id = 9 };
    metadata = .fixed(&metadata_buffer);
    try writeLiveMetadata(&job, .identity, 0, null, &metadata);
    try std.testing.expectEqualStrings(
        "{\"id\":9,\"ok\":false,\"error\":\"render snapshot too large\"}",
        metadata.buffered(),
    );
}

test "render server: a live delta ships only the region that moved" {
    const head = "<!doctype html><html><body>" ++ ("<p>static</p>" ** 200);
    const tail = ("<p>tail</p>" ** 200) ++ "</body></html>";
    const first = head ++ "<b>0</b>" ++ tail;
    const second = head ++ "<b>1</b>" ++ tail;

    const delta = snapshotDelta(first, second).?;
    try std.testing.expectEqual(first.len, delta.base_bytes);
    try std.testing.expectEqualStrings("1", delta.body);
    // The three wire fields must rebuild the document exactly.
    try std.testing.expectEqualStrings(first[0..delta.prefix], second[0..delta.prefix]);
    try std.testing.expectEqualStrings(
        first[first.len - delta.suffix ..],
        second[second.len - delta.suffix ..],
    );
    try std.testing.expectEqual(second.len, delta.prefix + delta.body.len + delta.suffix);

    // No base yet (the first frame of a connection) and a document that changed
    // too much to be worth patching both fall back to the full snapshot.
    try std.testing.expect(snapshotDelta("", second) == null);
    try std.testing.expect(snapshotDelta(first, "") == null);
    try std.testing.expect(snapshotDelta("aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb") == null);

    // Growth and shrinkage keep the shared head and tail, and the window is
    // trimmed to what actually differs -- the leading "0" is shared here.
    const longer = head ++ "<b>0123</b>" ++ tail;
    const grown = snapshotDelta(first, longer).?;
    try std.testing.expectEqualStrings("123", grown.body);
    try std.testing.expectEqual(longer.len, grown.prefix + grown.body.len + grown.suffix);
    const shrunk = snapshotDelta(longer, first).?;
    try std.testing.expectEqualStrings("", shrunk.body);
    try std.testing.expectEqual(first.len, shrunk.prefix + shrunk.body.len + shrunk.suffix);

    var metadata_buffer: [512]u8 = undefined;
    var metadata: std.Io.Writer = .fixed(&metadata_buffer);
    var sink_buffer: [1]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);
    const version: [16]u8 = "0123456789abcdef".*;
    var job: Job = .{
        .body = "",
        .out = &sink,
        .live_outcome = .{ .id = 3, .snapshot = true, .target_version = version },
    };
    try writeLiveMetadata(&job, .identity, delta.body.len, delta, &metadata);
    try std.testing.expect(std.mem.indexOf(
        u8,
        metadata.buffered(),
        "\"snapshot_bytes\":1,\"snapshot_delta\":{\"prefix\":",
    ) != null);
}

test "render server: live snapshot compression is negotiated and bounded" {
    const input = "<!doctype html><main>Lightpanda live snapshot</main>" ** 256;

    const preferences = liveCompressionPreferences("br,gzip,identity");
    var encoded: ResponseBuffer = .init(std.testing.allocator, input.len);
    defer encoded.deinit();

    const compressed = encodeLiveSnapshot(input, preferences, &encoded);
    try std.testing.expectEqual(Compression.Encoding.br, compressed.encoding);
    try std.testing.expect(compressed.bytes.len < input.len);

    const small = encodeLiveSnapshot("small", preferences, &encoded);
    try std.testing.expectEqual(Compression.Encoding.identity, small.encoding);
    try std.testing.expectEqualStrings("small", small.bytes);

    var randomish: [2_048]u8 = undefined;
    for (&randomish, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% i / 7);
    const entropy = encodeLiveSnapshot(&randomish, preferences, &encoded);
    try std.testing.expectEqual(Compression.Encoding.identity, entropy.encoding);
    try std.testing.expectEqualSlices(u8, &randomish, entropy.bytes);

    var bounded: ResponseBuffer = .init(std.testing.allocator, 8);
    defer bounded.deinit();
    const fallback = encodeLiveSnapshot(input, preferences, &bounded);
    try std.testing.expectEqual(Compression.Encoding.identity, fallback.encoding);
    try std.testing.expectEqualStrings(input, fallback.bytes);

    const unsupported = liveCompressionPreferences(null);
    try std.testing.expectEqual(Compression.Encoding.identity, unsupported.preferred());
}

// Chrome's DecompressionStream implements gzip but not br, so every live
// snapshot from a real browser takes the gzip path on a connection thread. The
// encoder frame outgrew the old hand-written 768 KiB budget and overran the
// guard page, taking the whole process down with it. Run the real encoder on a
// real thread of the configured size: if the budget is ever short again, this
// dies here instead of in front of a user.
test "render server: a connection thread's stack survives the gzip encoder" {
    const input = "<!doctype html><main>Lightpanda live snapshot</main>" ** 256;
    const Case = struct {
        fn run(body: []const u8) void {
            var encoded: ResponseBuffer = .init(std.testing.allocator, body.len);
            defer encoded.deinit();
            const compressed = encodeLiveSnapshot(body, .{ .gzip = 1000 }, &encoded);
            std.debug.assert(compressed.encoding == .gzip);
            std.debug.assert(compressed.bytes.len < body.len);
        }
    };
    const thread = try std.Thread.spawn(
        .{ .stack_size = connection_stack_size },
        Case.run,
        .{input},
    );
    thread.join();
}

test "render server: job deadlines preserve only remaining time" {
    const deadline = std.Io.Timestamp.fromNanoseconds(500 * ns_per_ms);
    try std.testing.expectEqual(
        @as(?u32, 250),
        remainingWaitMs(deadline, .fromNanoseconds(250 * ns_per_ms)),
    );
    try std.testing.expectEqual(
        @as(?u32, 1),
        remainingWaitMs(deadline, .fromNanoseconds(500 * ns_per_ms - 1)),
    );
    try std.testing.expectEqual(@as(?u32, null), remainingWaitMs(deadline, deadline));
    try std.testing.expectEqual(
        @as(?u32, null),
        remainingWaitMs(deadline, .fromNanoseconds(501 * ns_per_ms)),
    );
}

test "render server: queue push wakes a timed waiter" {
    var queue: Queue = .{};
    var output_buffer: [1]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    var job: Job = .{
        .body = "",
        .out = &output,
    };
    var waiter: struct {
        queue: *Queue,
        ready: std.Io.Event = .unset,
        result: ?*Job = null,

        fn run(self: *@This()) void {
            self.result = self.queue.popForWaiting(.any, 1_000, &self.ready);
        }
    } = .{ .queue = &queue };

    const thread = try std.Thread.spawn(.{}, @TypeOf(waiter).run, .{&waiter});
    waiter.ready.waitUncancelable(lp.io);
    try std.testing.expect(queue.push(&job));
    thread.join();
    try std.testing.expect(waiter.result == &job);
}

test "render server: only the live worker can take live jobs" {
    // A live command pins the Session and V8 context of the worker that
    // opened it. If a render-only worker could take one, it would answer
    // against a browser that has no such session.
    var queue: Queue = .{};
    var output_buffer: [1]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);

    var render_job: Job = .{ .kind = .render, .body = "", .out = &output };
    var live_job: Job = .{ .kind = .live, .body = "", .out = &output };
    var close_job: Job = .{ .kind = .live_close, .body = "", .out = &output };

    try std.testing.expect(queue.push(&render_job));
    try std.testing.expect(queue.push(&live_job));
    try std.testing.expect(queue.push(&close_job));

    // A render-only worker never sees either live job...
    try std.testing.expect(queue.tryPop(.render_only) == &render_job);
    try std.testing.expect(queue.tryPop(.render_only) == null);

    // ...and the live worker drains them in order, live before render.
    try std.testing.expect(queue.tryPop(.live_only) == &live_job);
    try std.testing.expect(queue.tryPop(.any) == &close_job);
    try std.testing.expect(queue.tryPop(.any) == null);

    // `.any` prefers a queued live command over a waiting render, so a live
    // client is never stuck behind someone else's page load.
    try std.testing.expect(queue.push(&render_job));
    try std.testing.expect(queue.push(&live_job));
    try std.testing.expect(queue.tryPop(.any) == &live_job);
    try std.testing.expect(queue.tryPop(.any) == &render_job);
}

test "render server: closed queue drains jobs accepted before close" {
    var queue: Queue = .{};
    var output_buffer: [1]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    var job: Job = .{
        .body = "",
        .out = &output,
    };

    try std.testing.expect(queue.popFor(.any, 0) == null);
    try std.testing.expect(queue.push(&job));
    queue.close();
    try std.testing.expect(!queue.closedAndEmpty());
    try std.testing.expect(queue.tryPop(.any) == &job);
    try std.testing.expect(queue.closedAndEmpty());
}

test "render server: public binds require authentication" {
    try std.testing.expect(isLoopback(.{ .ip4 = .loopback(9223) }));
    try std.testing.expect(isLoopback(.{ .ip6 = .loopback(9223) }));
    try std.testing.expect(!isLoopback(.{ .ip4 = .unspecified(9223) }));
    try std.testing.expect(!isLoopback(.{ .ip6 = .unspecified(9223) }));
}

test "render server: JSON content type requires a token boundary" {
    try std.testing.expect(isJsonContentType("application/json"));
    try std.testing.expect(isJsonContentType("Application/JSON; charset=utf-8"));
    try std.testing.expect(!isJsonContentType("application/jsonp"));
    try std.testing.expect(!isJsonContentType("text/plain"));
}

test "render server: invalid render requests fail during preparation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var output_buffer: [1]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);

    const bodies = [_][]const u8{
        "{",
        "{\"url\":\"file:///etc/passwd\"}",
        "{\"url\":\"https://example.com\",\"width\":0}",
    };
    for (bodies) |body| {
        var job: Job = .{ .body = body, .out = &output };
        try std.testing.expect(prepareRender(testing.test_app.config, arena.allocator(), &job) == null);
        try std.testing.expectEqual(Result.bad_request, job.result);
    }
}

test "render server: direct client resources are explicit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var output_buffer: [1]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    var job: Job = .{
        .body = "{\"url\":\"https://example.com\",\"direct_resources\":\"on\"}",
        .out = &output,
    };

    const request = prepareRender(testing.test_app.config, arena.allocator(), &job).?;
    try std.testing.expect(request.direct_resources);

    // Omitted means off: the CSP blocks every external subresource rather than
    // splitting the page load across two clients behind the caller's back.
    job = .{ .body = "{\"url\":\"https://example.com\"}", .out = &output };
    const default = prepareRender(testing.test_app.config, arena.allocator(), &job).?;
    try std.testing.expect(!default.direct_resources);

    // `auto` resolves against the deployment's stealth setting, not the request.
    job = .{
        .body = "{\"url\":\"https://example.com\",\"direct_resources\":\"auto\"}",
        .out = &output,
    };
    const automatic = prepareRender(testing.test_app.config, arena.allocator(), &job).?;
    try std.testing.expectEqual(!testing.test_app.config.stealth(), automatic.direct_resources);

    job = .{
        .body = "{\"url\":\"https://example.com\",\"direct_resources\":true}",
        .out = &output,
    };
    try std.testing.expect(prepareRender(testing.test_app.config, arena.allocator(), &job) == null);
}

test "render server: websocket ticket is decoded and single use" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const target = "/v1/live?other=x&ticket=a%2Bb+c";
    try std.testing.expectEqualStrings("a+b c", (try queryValue(arena.allocator(), target, "ticket")).?);
    try std.testing.expect(tokenEqual("0123456789abcdef", "0123456789abcdef"));
    try std.testing.expect(!tokenEqual("0123456789abcdee", "0123456789abcdef"));
    try std.testing.expect(!tokenEqual("short", "0123456789abcdef"));

    var tickets = try LiveTickets.init(std.testing.allocator, 2);
    defer tickets.deinit(std.testing.allocator);
    const first = try tickets.issue();
    const second = try tickets.issue();
    try std.testing.expect(tickets.consume(&first));
    try std.testing.expect(tickets.consume(&second));
    try std.testing.expect(!tickets.consume(&first));
}

test "render server: live ticket capacity and TTL are deterministic" {
    var tickets = try LiveTickets.init(std.testing.allocator, 2);
    defer tickets.deinit(std.testing.allocator);

    const first = "11111111111111111111111111111111".*;
    const second = "22222222222222222222222222222222".*;
    const third = "33333333333333333333333333333333".*;
    const one_ms = std.Io.Timestamp.fromNanoseconds(ns_per_ms);
    const two_ms = std.Io.Timestamp.fromNanoseconds(2 * ns_per_ms);
    const three_ms = std.Io.Timestamp.fromNanoseconds(3 * ns_per_ms);

    tickets.insertAt(first, one_ms);
    tickets.insertAt(second, two_ms);
    tickets.insertAt(third, three_ms);
    try std.testing.expect(!tickets.consumeAt(&first, three_ms));
    try std.testing.expect(tickets.consumeAt(&second, three_ms));
    try std.testing.expect(tickets.consumeAt(&third, three_ms));

    tickets.insertAt(first, one_ms);
    const expired_at = std.Io.Timestamp.fromNanoseconds((live_ticket_ttl_ms + 2) * ns_per_ms);
    try std.testing.expect(!tickets.consumeAt(&first, expired_at));
}

test "render server: known body is borrowed and bounded" {
    var transfer_buf: [32]u8 = undefined;
    var reader: std.testing.Reader = .init(&transfer_buf, &.{.{ .buffer = "request body" }});
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const body = try readRequestBody(arena.allocator(), &reader.interface, "request body".len, 1024);
    try std.testing.expectEqualStrings("request body", body);
    try std.testing.expectEqual(0, arena.queryCapacity());
    try std.testing.expectError(
        error.StreamTooLong,
        readRequestBody(arena.allocator(), &reader.interface, 1025, 1024),
    );
}

test "render server: websocket bridge drains buffered upgrade bytes" {
    const frame = [_]u8{
        0x81,    0x82,
        1,       2,
        3,       4,
        'o' ^ 1, 'k' ^ 2,
    };
    var transfer_buf: [32]u8 = undefined;
    var input: std.testing.Reader = .init(
        &transfer_buf,
        &.{.{ .buffer = "unexpected socket read" }},
    );
    @memcpy(input.interface.buffer[0..frame.len], &frame);
    input.interface.end = frame.len;

    var reader = try WS.Reader(true).init(std.testing.allocator, 1024);
    defer reader.deinit();

    const message = try readLiveMessage(&input.interface, &reader);
    try std.testing.expectEqual(WS.Message.Type.text, message.type);
    try std.testing.expectEqualStrings("ok", message.data);
    try std.testing.expectEqual(0, input.next_call_index);
}

test "render server: websocket bridge progresses after an indirect read" {
    const frame = [_]u8{
        0x81,    0x82,
        5,       6,
        7,       8,
        'o' ^ 5, 'k' ^ 6,
    };
    var source_buf: [16]u8 = undefined;
    var source: std.testing.Reader = .init(
        &source_buf,
        &.{.{ .buffer = &frame }},
    );
    var indirect_buf: [32]u8 = undefined;
    var indirect: std.testing.ReaderIndirect = .init(
        &source.interface,
        &indirect_buf,
    );
    var reader = try WS.Reader(true).init(std.testing.allocator, 1024);
    defer reader.deinit();

    const message = try readLiveMessage(&indirect.interface, &reader);
    try std.testing.expectEqual(WS.Message.Type.text, message.type);
    try std.testing.expectEqualStrings("ok", message.data);
    try std.testing.expectEqual(1, source.next_call_index);
}

test "render server: websocket bridge maps internal allocation failure" {
    try std.testing.expectEqualSlices(
        u8,
        &live_close_internal_error,
        liveCloseFrameForError(error.OutOfMemory).?,
    );
}

test "render server: URL schemes and credentials are rejected" {
    const Request = struct { url: []const u8 };
    const cases = [_][]const u8{
        "file:///etc/passwd",
        "data:text/html,hello",
        "javascript:alert(1)",
        "https://user:pass@example.com/",
    };
    for (cases) |url| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const request: Request = .{ .url = url };
        const canonical = lp.URL.resolveNavigation(arena.allocator(), request.url, .{}) catch continue;
        const protocol = lp.URL.getProtocol(canonical);
        const valid = (std.mem.eql(u8, protocol, "http:") or std.mem.eql(u8, protocol, "https:")) and
            lp.URL.getUsername(canonical).len == 0 and lp.URL.getPassword(canonical).len == 0;
        try std.testing.expect(!valid);
    }
}
