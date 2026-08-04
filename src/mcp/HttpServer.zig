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

//! HTTP transport for the browser-tools MCP server and W3C WebDriver endpoint.
//!
//! Lets many clients drive one process, each on its own browsing session.
//! Threading rule: V8 isolates are thread-affine, so ALL browser work — every
//! session's Browser/Session — lives on a single worker thread that owns the
//! `Server`. Connection threads never touch a browser; they parse HTTP,
//! marshal a `Job` to the worker over a queue, block on its completion, then
//! write the response. Session routing follows the `Mcp-Session-Id` header:
//! an `initialize` without one mints a fresh session (isolation by default);
//! reusing an id joins that session (sharing on purpose).

const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const sys_net = @import("../sys/net.zig");

const Server = @import("Server.zig");
const ResponseBuffer = @import("ResponseBuffer.zig");
const router = @import("router.zig");
const webdriver = @import("webdriver.zig");

const log = lp.log;
const posix = std.posix;

const HttpServer = @This();

pub const Protocol = enum { mcp, webdriver };

const ns_per_ms = std.time.ns_per_ms;

// The browser worker enters V8 and needs recursion headroom. Connection
// threads only parse HTTP and wait for the worker, so a much smaller stack is
// sufficient. Zig's default is 16 MiB for both kinds of thread.
const worker_stack_size = 4 * 1024 * 1024;
const connection_stack_size = 256 * 1024;

// Keep hot-path allocations reusable without allowing one unusually large
// request or response to pin megabytes for the lifetime of a keep-alive
// connection.
const retained_arena_bytes = 64 * 1024;
const retained_response_bytes = 64 * 1024;

const response_too_large =
    "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603," ++
    "\"message\":\"Response too large\"}}\n";

const max_webdriver_request_bytes = 1024 * 1024;
const max_webdriver_connections: u32 = 16;
const webdriver_retain_bytes = 64 * 1024;
// Bound every blocking socket read so a partial local request cannot reserve
// one of the endpoint's 16 connection slots forever.
const webdriver_socket_timeout_ms: i64 = 10_000;
const webdriver_forbidden_body =
    "{\"value\":{\"error\":\"unknown error\",\"message\":\"WebDriver accepts only loopback Host headers and non-browser requests\",\"stacktrace\":\"\"}}";
const webdriver_response_too_large =
    "{\"value\":{\"error\":\"unknown error\",\"message\":\"Response too large\",\"stacktrace\":\"\"}}";

/// One unit of work handed from a connection thread to the browser worker.
/// Allocated on the connection thread's stack — safe because that thread
/// blocks on `done` for the whole time the worker reads `body`/`session_id`
/// and writes `out`.
const Job = struct {
    kind: Kind,
    method: std.http.Method = .GET,
    target: []const u8 = "",
    body: []const u8,
    session_id: ?[]const u8,
    /// Where the worker writes the response. The connection thread owns the
    /// backing buffer and reads it back once `done` fires.
    out: *std.Io.Writer,

    /// Session id the worker actually routed to; echoed back as
    /// `Mcp-Session-Id`. Stored in a fixed buffer (not a worker arena) so it
    /// outlives the worker moving on to the next job.
    assigned_buf: [128]u8 = undefined,
    assigned_len: usize = 0,
    status: std.http.Status = .ok,
    // Set by the worker only when this New Session request created the sole
    // endpoint session. A failed response write then rolls it back on worker.
    created_webdriver_session_id: ?[36]u8 = null,

    done: std.Io.Event = .unset,
    next: ?*Job = null,

    const Kind = enum { rpc, close, webdriver, webdriver_rollback };

    fn assigned(self: *const Job) []const u8 {
        return self.assigned_buf[0..self.assigned_len];
    }

    fn setAssigned(self: *Job, id: []const u8) void {
        const n = @min(id.len, self.assigned_buf.len);
        @memcpy(self.assigned_buf[0..n], id[0..n]);
        self.assigned_len = n;
    }
};

const Queue = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    head: ?*Job = null,
    tail: ?*Job = null,
    closed: std.atomic.Value(bool) = .init(false),

    fn push(self: *Queue, job: *Job) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        job.next = null;
        if (self.tail) |t| t.next = job else self.head = job;
        self.tail = job;
        self.cond.signal(lp.io);
    }

    /// Pop the next job, waiting at most `timeout_ms`. Returns null on timeout
    /// (or spurious wakeup) so the worker can pump idle sessions and retry;
    /// check `closed` to tell shutdown from timeout.
    fn pop(self: *Queue, timeout_ms: u64) ?*Job {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self.head == null) {
            if (timeout_ms == 0 or self.closed.load(.acquire)) return null;
            lp.timedWait(&self.cond, &self.mutex, timeout_ms * ns_per_ms) catch {};
        }
        const job = self.head orelse return null;
        self.head = job.next;
        if (self.head == null) self.tail = null;
        return job;
    }

    fn close(self: *Queue) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.closed.store(true, .release);
        self.cond.signal(lp.io);
    }
};

allocator: std.mem.Allocator,
app: *App,
protocol: Protocol,
max_connections: u32,
max_request_size: usize,
max_response_size: usize,

queue: Queue = .{},

// Registration happens in onAccept — the same (network) thread deinit runs
// on — so a connection is always counted and its socket registered before
// deinit can observe either.
active_conns: std.atomic.Value(u32) = .init(0),
conn_mutex: std.Io.Mutex = .init,
conns: std.ArrayList(posix.socket_t) = .empty,
active_worker_mutex: std.Io.Mutex = .init,
active_worker_env: ?*lp.js.Env = null,
active_worker_termination_sent: bool = false,
// `/status` uses this rather than queuing behind a stuck browser execution.
webdriver_ready: std.atomic.Value(bool) = .init(true),

// The worker owns `server`; other threads must not touch it.
worker_thread: std.Thread = undefined,
worker_ready: std.Io.Event = .unset,
worker_ok: bool = false,

/// Create the server and start its browser worker thread. Returns once the
/// worker's default session is up (or errors if it failed to initialize).
pub fn init(allocator: std.mem.Allocator, app: *App, protocol: Protocol) !*HttpServer {
    if (protocol == .webdriver and
        !webdriverNetworkSettingsSupported(app.config.httpProxy(), app.config.tlsVerifyHost()))
    {
        return error.WebDriverNetworkConfigurationUnsupported;
    }

    const self = try allocator.create(HttpServer);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .app = app,
        .protocol = protocol,
        .max_connections = app.config.maxConnections(),
        .max_request_size = app.config.mcpMaxRequestSize(),
        .max_response_size = app.config.mcpMaxResponseSize(),
    };
    errdefer self.conns.deinit(allocator);

    // The configured cap is small (16 in MCP mode). Reserving the descriptor
    // list once removes allocator calls from the accept path and makes every
    // admitted socket trackable during shutdown.
    try self.conns.ensureTotalCapacity(allocator, self.max_connections);

    self.worker_thread = try std.Thread.spawn(.{ .stack_size = worker_stack_size }, worker, .{self});
    self.worker_ready.waitUncancelable(lp.io);
    if (!self.worker_ok) {
        self.worker_thread.join();
        return error.WorkerInitFailed;
    }
    if (protocol == .webdriver) self.webdriver_ready.store(true, .release);
    return self;
}

/// Runs after the accept loop has stopped, so no new connection can arrive.
/// Shutting the sockets down unblocks the connection threads' pending reads;
/// the worker must outlive their drain because a connection thread may still
/// be blocked on `job.done`.
pub fn deinit(self: *HttpServer) void {
    {
        self.conn_mutex.lockUncancelable(lp.io);
        defer self.conn_mutex.unlock(lp.io);
        for (self.conns.items) |socket| {
            sys_net.shutdown(socket, .both) catch {};
        }
    }
    while (self.active_conns.load(.acquire) > 0) {
        if (self.protocol == .webdriver) self.terminateActiveWorker();
        lp.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }

    self.queue.close();
    self.worker_thread.join();

    self.conns.deinit(self.allocator);
    self.allocator.destroy(self);
}

/// Accept MCP-over-HTTP connections until the network loop is stopped
/// (e.g. by the signal handler). Reuses the shared accept infrastructure;
/// blocks the calling thread in `Network.run`.
pub fn run(self: *HttpServer, address: sys_net.IpAddress) !void {
    if (self.protocol == .webdriver and !isLoopbackAddress(address)) {
        log.err(.mcp, "webdriver only accepts loopback binds", .{ .address = address });
        return error.WebDriverLoopbackOnly;
    }

    var bound = address;
    try self.app.network.bind(&bound, self, onAccept);
    switch (self.protocol) {
        .mcp => log.note(.mcp, "mcp http server running", .{ .address = bound }),
        .webdriver => log.note(.mcp, "webdriver server running", .{ .address = bound }),
    }
    self.app.network.run();
}

/// Network hands us a nonblocking accepted socket; each connection is served
/// by its own thread doing blocking IO, so we clear O_NONBLOCK first.
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

    if (!acquireConnectionSlot(&self.active_conns, self.connectionLimit())) {
        _ = std.c.close(socket);
        return;
    }

    {
        self.conn_mutex.lockUncancelable(lp.io);
        defer self.conn_mutex.unlock(lp.io);
        self.conns.appendAssumeCapacity(socket);
    }

    const thread = std.Thread.spawn(.{ .stack_size = connection_stack_size }, handleConn, .{ self, socket }) catch |err| {
        log.warn(.mcp, "mcp spawn", .{ .err = err });
        _ = self.active_conns.fetchSub(1, .release);
        self.unregister(socket);
        _ = std.c.close(socket);
        return;
    };
    thread.detach();
}

/// The WebDriver endpoint is a single-session protocol; cap it below whatever
/// the MCP-oriented configuration allows.
fn connectionLimit(self: *const HttpServer) u32 {
    return switch (self.protocol) {
        .mcp => self.max_connections,
        .webdriver => @min(self.max_connections, max_webdriver_connections),
    };
}

/// Bytes of arena/response capacity worth keeping between requests.
fn retainBytes(self: *const HttpServer, mcp_bytes: usize) usize {
    return switch (self.protocol) {
        .mcp => mcp_bytes,
        .webdriver => webdriver_retain_bytes,
    };
}

/// Reserve one connection slot without ever exceeding the configured cap.
/// The accept loop is currently single-threaded, but keeping this atomic makes
/// the invariant independent of that implementation detail.
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
    for (self.conns.items, 0..) |s, i| {
        if (s == socket) {
            _ = self.conns.swapRemove(i);
            break;
        }
    }
}

fn worker(self: *HttpServer) void {
    var placeholder: std.Io.Writer.Allocating = .init(self.allocator);
    defer placeholder.deinit();

    const server = switch (self.protocol) {
        .mcp => Server.init(self.allocator, self.app, &placeholder.writer),
        .webdriver => Server.initWebDriver(self.allocator, self.app, &placeholder.writer),
    } catch |err| {
        log.err(.mcp, "mcp http server init", .{ .err = err });
        self.worker_ready.set(lp.io);
        return;
    };
    defer {
        // `TerminateExecution` is sticky. Cancel it while the worker still
        // owns the isolate, before Browser.deinit tears the isolate down.
        if (self.protocol == .webdriver) server.cancelWebDriverTermination();
        server.deinit();
    }

    server.enableIsolateParking();

    self.worker_ok = true;
    self.worker_ready.set(lp.io);

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();

    // Drain queued jobs before pumping idle work: idle() enters and ticks
    // every live session (blocking up to 25ms each), so pumping between
    // every two jobs would cap throughput at one job per full pass.
    var wait_ms: u64 = 0;
    while (true) {
        const job = self.queue.pop(wait_ms) orelse {
            if (self.queue.closed.load(.acquire)) break;
            if (self.protocol == .webdriver) {
                self.setActiveWorkerEnvironment(server.webdriverEnvironment());
                wait_ms = server.idle();
                server.cancelWebDriverTermination();
                self.setActiveWorkerEnvironment(null);
            } else {
                wait_ms = server.idle();
            }
            continue;
        };
        self.process(server, arena.allocator(), job);
        // Drop oversized transient allocations before the worker goes idle.
        _ = arena.reset(.{ .retain_with_limit = self.retainBytes(retained_arena_bytes) });
        job.done.set(lp.io);
        wait_ms = 0;
    }
}

fn process(self: *HttpServer, server: *Server, arena: std.mem.Allocator, job: *Job) void {
    server.transport.retarget(job.out);

    if (job.kind == .webdriver) {
        const creating_session = isWebDriverNewSession(job.method, job.target);
        if (creating_session) self.webdriver_ready.store(false, .release);
        const publishes_environment = job.method != .DELETE;
        if (publishes_environment) self.setActiveWorkerEnvironment(server.webdriverEnvironment());
        defer if (publishes_environment) self.setActiveWorkerEnvironment(null);
        job.status = webdriver.handle(server, arena, job.method, job.target, job.body, job.out) catch |err| blk: {
            log.err(.mcp, "webdriver handle", .{ .err = err });
            job.out.writeAll("{\"value\":{\"error\":\"unknown error\",\"message\":\"Internal server error\",\"stacktrace\":\"\"}}") catch {};
            break :blk .internal_server_error;
        };
        if (creating_session and job.status == .ok) {
            if (server.webdriver_session_id) |id| {
                job.created_webdriver_session_id = id;
            }
        }
        self.webdriver_ready.store(server.webdriverReady(), .release);
        return;
    }

    if (job.kind == .webdriver_rollback) {
        const id = job.session_id orelse unreachable;
        _ = server.closeWebDriverSession(id);
        self.webdriver_ready.store(server.webdriverReady(), .release);
        return;
    }

    if (job.kind == .close) {
        if (job.session_id) |sid| _ = server.closeSession(sid);
        return;
    }

    const chosen = resolveSession(server, arena, job) catch |err| {
        log.err(.mcp, "mcp session routing", .{ .err = err });
        server.sendError(
            .null,
            .InternalError,
            if (err == error.SessionLimitReached) "Session limit reached" else "Session routing failed",
        ) catch |send_err| log.err(.mcp, "mcp session error response", .{ .err = send_err });
        return;
    };
    job.setAssigned(chosen);

    router.handleMessage(server, arena, job.body) catch |err| {
        log.err(.mcp, "mcp handle", .{ .err = err });
    };
}

fn setActiveWorkerEnvironment(self: *HttpServer, env: ?*lp.js.Env) void {
    self.active_worker_mutex.lockUncancelable(lp.io);
    defer self.active_worker_mutex.unlock(lp.io);
    self.active_worker_env = env;
    self.active_worker_termination_sent = false;
}

fn terminateActiveWorker(self: *HttpServer) void {
    self.active_worker_mutex.lockUncancelable(lp.io);
    defer self.active_worker_mutex.unlock(lp.io);
    if (self.active_worker_termination_sent) return;
    const env = self.active_worker_env orelse return;
    self.active_worker_termination_sent = true;
    env.requestTerminate();
}

fn isWebDriverNewSession(method: std.http.Method, target: []const u8) bool {
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return method == .POST and std.mem.eql(u8, target[0..path_end], "/session");
}

/// Decide which session a request targets and make it active. An explicit
/// `Mcp-Session-Id` wins; otherwise `initialize` mints a new session and
/// everything else falls back to the default.
fn resolveSession(server: *Server, arena: std.mem.Allocator, job: *Job) ![]const u8 {
    if (job.session_id) |sid| {
        if (sid.len > 0) {
            _ = try server.useSession(sid);
            return sid;
        }
    }

    if (isInitialize(arena, job.body)) {
        const sid = try server.nextSessionId(arena);
        _ = try server.useSession(sid);
        return sid;
    }

    _ = try server.useSession(null);
    return Server.default_session_id;
}

fn isInitialize(arena: std.mem.Allocator, body: []const u8) bool {
    const Peek = struct { method: ?[]const u8 = null };
    const peek = std.json.parseFromSliceLeaky(Peek, arena, body, .{ .ignore_unknown_fields = true }) catch return false;
    const method = peek.method orelse return false;
    return std.mem.eql(u8, method, "initialize");
}

fn handleConn(self: *HttpServer, socket: posix.socket_t) void {
    defer _ = self.active_conns.fetchSub(1, .release);
    const stream: std.Io.net.Stream = .{ .socket = .{ .handle = socket, .address = .{ .ip4 = .unspecified(0) } } };
    defer stream.close(lp.io);
    // Runs before close (defers are LIFO): deinit's shutdown sweep must
    // never see an fd that has been closed and possibly reused.
    defer self.unregister(socket);

    if (self.protocol == .webdriver) {
        setWebDriverSocketTimeout(socket) catch |err| {
            log.warn(.mcp, "webdriver socket timeout", .{ .err = err });
            return;
        };
    }

    var recv_buf: [8 * 1024]u8 = undefined;
    var send_buf: [8 * 1024]u8 = undefined;
    var stream_reader = stream.reader(lp.io, &recv_buf);
    var stream_writer = stream.writer(lp.io, &send_buf);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    // Reused across requests (served serially), not reallocated per request.
    var out: ResponseBuffer = .init(self.allocator, self.max_response_size);
    defer out.deinit();

    while (true) {
        var request = http_server.receiveHead() catch return; // peer closed, bad head, or shutdown
        const keep_alive = self.serve(&out, arena.allocator(), &request) catch return;
        // Trim before waiting for another keep-alive request. Otherwise a
        // quiet client can pin its largest request and response indefinitely.
        _ = arena.reset(.{ .retain_with_limit = self.retainBytes(retained_arena_bytes) });
        out.reset(self.retainBytes(retained_response_bytes));
        if (!keep_alive) return;
    }
}

/// Handle one request: marshal it to the browser worker and write the reply.
/// MCP Streamable HTTP — POST carries a JSON-RPC message; DELETE closes the
/// session named by `Mcp-Session-Id`. std.http.Server owns the framing.
/// Returns whether the connection is safe to reuse after the response.
fn serve(self: *HttpServer, out: *ResponseBuffer, arena: std.mem.Allocator, request: *std.http.Server.Request) !bool {
    if (self.protocol == .webdriver) return self.serveWebDriver(out, arena, request);

    const method = request.head.method;
    if (method != .POST and method != .DELETE) {
        try request.respond("", .{ .status = .method_not_allowed, .keep_alive = false });
        return false;
    }
    if (request.head.expect != null) {
        try request.respond("", .{ .status = .expectation_failed, .keep_alive = false });
        return false;
    }

    // Read the session header and keep_alive before the body reader
    // invalidates the head's string memory.
    const session_id = try sessionHeader(arena, request);
    const keep_alive = request.head.keep_alive;

    // Zig's HTTP server deliberately treats DELETE as bodyless. Reject a
    // framed DELETE body and close the connection; otherwise unread bytes
    // could be mistaken for the next keep-alive request.
    if (method == .DELETE and
        (request.head.transfer_encoding != .none or (request.head.content_length orelse 0) != 0))
    {
        try request.respond("", .{ .status = .bad_request, .keep_alive = false });
        return false;
    }

    // A POST may legally arrive with chunked transfer framing plus a
    // Content-Length header. That length does not describe the decoded body,
    // so only use the exact-allocation path for non-chunked requests.
    const content_length = if (request.head.transfer_encoding == .none)
        request.head.content_length
    else
        null;
    var body_buf: [8 * 1024]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buf);
    const body = readRequestBody(arena, body_reader, content_length, self.max_request_size) catch {
        try request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
        return false;
    };

    var job: Job = .{
        .kind = if (method == .DELETE) .close else .rpc,
        .body = body,
        .session_id = session_id,
        .out = &out.writer,
    };
    self.queue.push(&job);
    job.done.waitUncancelable(lp.io);

    const resp = if (out.failure != null) response_too_large else out.buffered();
    var headers: [2]std.http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "content-type", .value = "application/json" };
    n += 1;
    if (job.assigned_len > 0) {
        headers[n] = .{ .name = "mcp-session-id", .value = job.assigned() };
        n += 1;
    }
    const reuse = keep_alive and out.failure == null;
    try request.respond(resp, .{
        // An empty body means a notification (or a close): 202, no content.
        .status = if (resp.len == 0) .accepted else .ok,
        .keep_alive = reuse,
        .extra_headers = headers[0..n],
    });
    return reuse;
}

/// Read a request body with one allocation when Content-Length is known.
/// `allocRemaining` grows geometrically; with an arena, superseded buffers
/// cannot be reclaimed until reset and can nearly double peak body memory.
fn readRequestBody(
    arena: std.mem.Allocator,
    reader: *std.Io.Reader,
    content_length: ?u64,
    max_request_size: usize,
) ![]const u8 {
    if (content_length) |len64| {
        const len = std.math.cast(usize, len64) orelse return error.StreamTooLong;
        if (len > max_request_size) return error.StreamTooLong;
        // Most MCP messages fit in the transfer buffer. The connection thread
        // waits for the worker before reading again, so this borrowed slice is
        // stable for the full lifetime of Job and avoids a heap allocation.
        if (len <= reader.buffer.len) return try reader.take(len);

        const body = try arena.alloc(u8, len);
        try reader.readSliceAll(body);
        return body;
    }

    return try reader.allocRemaining(arena, .limited(max_request_size));
}

fn serveWebDriver(self: *HttpServer, out: *ResponseBuffer, arena: std.mem.Allocator, request: *std.http.Server.Request) !bool {
    if (!webDriverRequestHeadersAllowed(request)) {
        try request.respond(webdriver_forbidden_body, .{
            .status = .forbidden,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
        });
        return false;
    }
    if (request.head.expect != null) {
        try request.respond("", .{ .status = .expectation_failed, .keep_alive = false });
        return false;
    }

    const method = request.head.method;
    const target = try arena.dupe(u8, request.head.target);
    const keep_alive = request.head.keep_alive;
    if (method == .GET and std.mem.eql(u8, target, "/status")) {
        try request.respond(if (self.webdriver_ready.load(.acquire))
            "{\"value\":{\"ready\":true,\"message\":\"Lightpanda WebDriver endpoint is ready\"}}"
        else
            "{\"value\":{\"ready\":false,\"message\":\"Lightpanda WebDriver endpoint is busy\"}}", .{
            .status = .ok,
            .keep_alive = keep_alive,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
        return keep_alive;
    }

    const content_length = if (request.head.transfer_encoding == .none)
        request.head.content_length
    else
        null;
    var body_buf: [8 * 1024]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buf);
    const body = readRequestBody(arena, body_reader, content_length, max_webdriver_request_bytes) catch {
        try request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
        return false;
    };

    var job: Job = .{
        .kind = .webdriver,
        .method = method,
        .target = target,
        .body = body,
        .session_id = null,
        .out = &out.writer,
    };
    self.queue.push(&job);
    job.done.waitUncancelable(lp.io);

    const too_large = out.failure != null;
    const reuse = keep_alive and !too_large;
    request.respond(if (too_large) webdriver_response_too_large else out.buffered(), .{
        .status = if (too_large) .internal_server_error else job.status,
        .keep_alive = reuse,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    }) catch |err| {
        self.rollbackWebDriverSession(&job, &out.writer);
        return err;
    };
    if (too_large) self.rollbackWebDriverSession(&job, &out.writer);
    return reuse;
}

fn rollbackWebDriverSession(self: *HttpServer, completed: *const Job, out: *std.Io.Writer) void {
    const session_id = completed.created_webdriver_session_id orelse return;
    var rollback: Job = .{
        .kind = .webdriver_rollback,
        .body = "",
        .session_id = &session_id,
        .out = out,
    };
    self.queue.push(&rollback);
    rollback.done.waitUncancelable(lp.io);
}

fn setWebDriverSocketTimeout(socket: posix.socket_t) !void {
    const timeout = std.mem.toBytes(posix.timeval{
        .sec = @divTrunc(webdriver_socket_timeout_ms, 1000),
        .usec = @mod(webdriver_socket_timeout_ms, 1000) * 1000,
    });
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
}

fn webDriverRequestHeadersAllowed(request: *std.http.Server.Request) bool {
    // Loopback binding alone is insufficient against DNS rebinding and local
    // web-page CSRF. Native WebDriver clients send a loopback Host and no
    // Origin; reject requests that do not have that shape.
    var found_host = false;
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!webDriverHeaderAllowed(header.name, header.value)) return false;
        if (!std.ascii.eqlIgnoreCase(header.name, "host")) continue;
        if (found_host) return false;
        found_host = true;
    }
    return found_host;
}

fn webDriverHeaderAllowed(name: []const u8, value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "origin")) return false;
    if (std.ascii.eqlIgnoreCase(name, "host")) return isLoopbackHostHeader(value);
    return true;
}

fn isLoopbackHostHeader(value: []const u8) bool {
    var host = value;
    if (host.len == 0) return false;

    if (host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return false;
        if (!validHostPortSuffix(host[close + 1 ..])) return false;
        host = host[1..close];
    } else if (std.mem.count(u8, host, ":") == 1) {
        const colon = std.mem.lastIndexOfScalar(u8, host, ':').?;
        if (!validHostPortSuffix(host[colon..])) return false;
        host = host[0..colon];
    }

    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.eqlIgnoreCase(host, "localhost.")) {
        return true;
    }
    const address = std.Io.net.IpAddress.parse(host, 0) catch return false;
    return isLoopbackAddress(address);
}

fn validHostPortSuffix(suffix: []const u8) bool {
    if (suffix.len == 0) return true;
    if (suffix.len == 1 or suffix[0] != ':') return false;
    _ = std.fmt.parseInt(u16, suffix[1..], 10) catch return false;
    return true;
}

pub fn isLoopbackAddress(address: sys_net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| std.mem.eql(u8, &ip6.bytes, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }),
    };
}

pub fn webdriverNetworkSettingsSupported(http_proxy: ?[]const u8, tls_verify_host: bool) bool {
    // An empty CURLOPT_PROXY explicitly disables libcurl's ambient proxy
    // environment lookup; it is the direct-mode representation at runtime.
    return (http_proxy == null or http_proxy.?.len == 0) and tls_verify_host;
}

/// Duplicate the `Mcp-Session-Id` request header into `arena`, or null.
fn sessionHeader(arena: std.mem.Allocator, request: *std.http.Server.Request) !?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
            return try arena.dupe(u8, header.value);
        }
    }
    return null;
}

test "HttpServer - initialize is detected for session minting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expect(isInitialize(aa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"));
    try std.testing.expect(!isInitialize(aa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}"));
    try std.testing.expect(!isInitialize(aa, "not json"));
}

test "HttpServer - connection slots are bounded" {
    var active: std.atomic.Value(u32) = .init(0);
    try std.testing.expect(acquireConnectionSlot(&active, 2));
    try std.testing.expect(acquireConnectionSlot(&active, 2));
    try std.testing.expect(!acquireConnectionSlot(&active, 2));
    try std.testing.expectEqual(2, active.load(.monotonic));

    _ = active.fetchSub(1, .monotonic);
    try std.testing.expect(acquireConnectionSlot(&active, 2));
    try std.testing.expectEqual(2, active.load(.monotonic));
}

test "HttpServer - small known request body is borrowed" {
    var transfer_buf: [32]u8 = undefined;
    var reader: std.testing.Reader = .init(&transfer_buf, &.{.{ .buffer = "request body" }});

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const body = try readRequestBody(arena.allocator(), &reader.interface, "request body".len, 1024);
    try std.testing.expectEqualStrings("request body", body);
    try std.testing.expectEqual(0, arena.queryCapacity());
}

test "HttpServer - large known request body uses exact allocation" {
    const input = "x" ** 64;
    var transfer_buf: [8]u8 = undefined;
    var reader: std.testing.Reader = .init(&transfer_buf, &.{.{ .buffer = input }});

    var backing: [input.len]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&backing);

    const body = try readRequestBody(fba.allocator(), &reader.interface, input.len, 1024);
    try std.testing.expectEqualStrings(input, body);
    try std.testing.expectEqual(body.len, fba.end_index);
}

test "HttpServer - oversized known body is rejected before allocation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var reader: std.Io.Reader = .fixed("");
    try std.testing.expectError(
        error.StreamTooLong,
        readRequestBody(arena.allocator(), &reader, 1025, 1024),
    );
    try std.testing.expectEqual(0, arena.queryCapacity());
}

test "HttpServer - WebDriver binds only to loopback" {
    try std.testing.expect(isLoopbackAddress(try std.Io.net.IpAddress.parse("127.0.0.1", 9515)));
    try std.testing.expect(isLoopbackAddress(try std.Io.net.IpAddress.parse("::1", 9515)));
    try std.testing.expect(!isLoopbackAddress(try std.Io.net.IpAddress.parse("0.0.0.0", 9515)));
    try std.testing.expect(isLoopbackHostHeader("127.0.0.1:9515"));
    try std.testing.expect(isLoopbackHostHeader("[::1]:9515"));
    try std.testing.expect(isLoopbackHostHeader("localhost"));
    try std.testing.expect(!isLoopbackHostHeader("example.com:9515"));
    try std.testing.expect(!isLoopbackHostHeader("127.0.0.1:bad"));
    try std.testing.expect(!webDriverHeaderAllowed("Origin", "https://example.com"));
    try std.testing.expect(webDriverHeaderAllowed("Host", "127.0.0.1:9515"));
    try std.testing.expect(webdriverNetworkSettingsSupported(null, true));
    try std.testing.expect(webdriverNetworkSettingsSupported("", true));
    try std.testing.expect(!webdriverNetworkSettingsSupported("http://127.0.0.1:8080", true));
    try std.testing.expect(!webdriverNetworkSettingsSupported(null, false));
    try std.testing.expect(isWebDriverNewSession(.POST, "/session?trace=true"));
    try std.testing.expect(!isWebDriverNewSession(.GET, "/session"));
}
