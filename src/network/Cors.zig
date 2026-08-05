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

// CORS (Fetch §3.2) for the HttpClient request pipeline. A request only
// participates when its initiator attached `Params` — today fetch() and
// XMLHttpRequest. Everything else (navigations, scripts, stylesheets,
// internal fetches) is unchecked.
//
// Unlike the robots gate, this one FAILS CLOSED: the browser's default is
// to block, so a missing or unparseable Access-Control-Allow-Origin blocks.
//
// ponytail: deliberately not covered — Sec-Fetch-* metadata headers,
// CORB/ORB, Private Network Access preflights, redirect taint tracking
// across hops (the response check runs against the FINAL url, which is
// stricter than spec, not looser), and the crossorigin attribute on
// <img>/<script>/<link>. Add when a real site needs them.

const std = @import("std");
const lp = @import("lightpanda");

const URL = @import("../browser/URL.zig");
const Method = @import("http.zig").Method;
const Transfer = @import("HttpClient.zig").Transfer;

const log = lp.log;
const Allocator = std.mem.Allocator;

const Cors = @This();

pub const Mode = enum { cors, same_origin, no_cors };

// Per-request CORS state. Attached by the initiating API; null means "not
// subject to CORS".
pub const Params = struct {
    // The initiator's serialized origin ("http://example.com:8080").
    origin: []const u8,
    mode: Mode = .cors,
    // Fetch's "credentials mode is include" for a cross-origin request.
    credentialed: bool = false,
};

pub const Result = enum { allowed, blocked, pending };

// ---------------------------------------------------------------------------
// Spec predicates
// ---------------------------------------------------------------------------

pub fn sameOrigin(arena: Allocator, origin: []const u8, url: [:0]const u8) bool {
    // ponytail: byte comparison of the serialized origins. Good enough
    // because both sides come out of URL.resolve/getOrigin; it does not
    // normalize a default port written explicitly (http://x:80 vs http://x).
    const other = (URL.getOrigin(arena, url) catch return false) orelse return false;
    return std.mem.eql(u8, origin, other);
}

// https://fetch.spec.whatwg.org/#cors-safelisted-request-header
fn safelistedRequestHeader(name: []const u8, value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "accept") or
        std.ascii.eqlIgnoreCase(name, "accept-language") or
        std.ascii.eqlIgnoreCase(name, "content-language"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "range")) {
        // ponytail: only the "bytes=" shape, no full range-syntax check.
        return std.ascii.startsWithIgnoreCase(value, "bytes=");
    }
    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        const essence = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, ';') orelse value.len], " \t");
        return std.ascii.eqlIgnoreCase(essence, "application/x-www-form-urlencoded") or
            std.ascii.eqlIgnoreCase(essence, "multipart/form-data") or
            std.ascii.eqlIgnoreCase(essence, "text/plain");
    }
    return false;
}

// https://fetch.spec.whatwg.org/#cors-safelisted-response-header-name
fn safelistedResponseHeader(name: []const u8) bool {
    const names = [_][]const u8{
        "cache-control", "content-language", "content-length",
        "content-type",  "expires",          "last-modified",
        "pragma",
    };
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

fn simpleMethod(method: Method) bool {
    return method == .GET or method == .HEAD or method == .POST;
}

// A request is "simple" (no preflight) when the method is safelisted and
// every script-set header is safelisted. `HeaderSource` is what makes this
// answerable: user-agent headers (Referer, cookies, UA) never count.
fn needsPreflight(transfer: *Transfer) bool {
    if (!simpleMethod(transfer.req.method)) {
        return true;
    }
    for (transfer.req_headers.items) |hdr| {
        if (hdr.source != .author) continue;
        if (!safelistedRequestHeader(hdr.name, hdr.value)) return true;
    }
    return false;
}

fn headerValue(transfer: *Transfer, name: []const u8) ?[]const u8 {
    var it = transfer.responseHeaderIterator();
    while (it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, name)) return hdr.value;
    }
    return null;
}

// https://fetch.spec.whatwg.org/#concept-cors-check — the shared
// Access-Control-Allow-Origin / -Allow-Credentials test. Used by the
// response gate below and by EventSource.
pub fn allowOriginMatches(transfer: *Transfer, origin: []const u8, credentialed: bool) bool {
    const allowed = headerValue(transfer, "access-control-allow-origin") orelse return false;
    if (std.mem.eql(u8, allowed, "*")) {
        // The wildcard never satisfies a credentialed request.
        return !credentialed;
    }
    if (!std.mem.eql(u8, allowed, origin)) {
        return false;
    }
    if (credentialed) {
        const creds = headerValue(transfer, "access-control-allow-credentials") orelse return false;
        return std.mem.eql(u8, creds, "true");
    }
    return true;
}

// Does a comma-separated list header (Allow-Methods / Allow-Headers /
// Expose-Headers) contain `needle`?
fn listContains(list: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t"), needle)) return true;
    }
    return false;
}

// Response-side gate, called for every delivered response. Fails closed.
pub fn responseAllowed(transfer: *Transfer) bool {
    const params = transfer.req.cors orelse return true;

    // no-cors never reads the response, so there is nothing to protect;
    // the initiator turns it into an opaque filtered response instead.
    if (params.mode == .no_cors) return true;

    if (sameOrigin(transfer.arena.allocator(), params.origin, transfer.req.url)) {
        return true;
    }
    if (params.mode == .same_origin) return false;

    return allowOriginMatches(transfer, params.origin, params.credentialed);
}

// Which response headers script may see. Null = no filtering (same-origin
// or not a CORS request).
pub const Expose = struct {
    list: []const u8,
    credentialed: bool,

    pub fn allows(self: Expose, name: []const u8) bool {
        if (safelistedResponseHeader(name)) return true;
        // "*" exposes everything except on a credentialed request.
        if (!self.credentialed and listContains(self.list, "*")) return true;
        return listContains(self.list, name);
    }
};

pub fn exposeFilter(transfer: *Transfer) ?Expose {
    const params = transfer.req.cors orelse return null;
    if (params.mode == .no_cors) return null;
    if (sameOrigin(transfer.arena.allocator(), params.origin, transfer.req.url)) return null;
    return .{
        .list = headerValue(transfer, "access-control-expose-headers") orelse "",
        .credentialed = params.credentialed,
    };
}

// ---------------------------------------------------------------------------
// Request-side gate (preflight)
// ---------------------------------------------------------------------------

allocator: Allocator,

// (origin, url, method) -> preflight grant. ponytail: entries expire on
// lookup only and the whole map is flushed past `max_cache`; swap in an LRU
// if a page ever preflights thousands of distinct endpoints.
cache: std.StringHashMapUnmanaged(Grant) = .empty,

// url -> transfers waiting on an in-flight preflight for it.
pending: std.StringHashMapUnmanaged(std.ArrayList(*Transfer)) = .empty,

const max_cache = 256;

const Grant = struct {
    expires_at: u64,
    allow_headers: []const u8,
    credentialed: bool,
};

pub fn deinit(self: *Cors) void {
    var cit = self.cache.iterator();
    while (cit.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.allow_headers);
    }
    self.cache.deinit(self.allocator);

    var pit = self.pending.valueIterator();
    while (pit.next()) |waiting| {
        waiting.deinit(self.allocator);
    }
    self.pending.deinit(self.allocator);
}

pub fn check(self: *Cors, transfer: *Transfer) !Result {
    const params = transfer.req.cors orelse return .allowed;
    const arena = transfer.arena.allocator();
    const method = transfer.req.method;

    if (sameOrigin(arena, params.origin, transfer.req.url)) {
        // Fetch §5.7: same-origin requests still carry Origin unless the
        // method is GET or HEAD.
        if (!(method == .GET or method == .HEAD)) {
            try transfer.setHeader("Origin", params.origin, .{});
        }
        return .allowed;
    }

    switch (params.mode) {
        .same_origin => {
            log.warn(.http, "cors blocked", .{ .url = transfer.req.url, .reason = "mode=same-origin" });
            return .blocked;
        },
        // Opaque: the initiator drops the body and headers, so there is
        // nothing to check. ponytail: the spec also clamps the method and
        // header set here; nothing in the wild depends on that.
        .no_cors => {
            try transfer.setHeader("Origin", params.origin, .{});
            return .allowed;
        },
        .cors => {},
    }

    try transfer.setHeader("Origin", params.origin, .{});
    if (!needsPreflight(transfer)) {
        return .allowed;
    }

    const key = try cacheKey(arena, params.origin, method, transfer.req.url);
    if (self.cache.get(key)) |grant| {
        if (grant.expires_at > lp.datetime.timestamp(.boot) and grant.credentialed == params.credentialed) {
            return if (headersAllowed(transfer, grant.allow_headers, params.credentialed)) .allowed else .blocked;
        }
    }

    try self.preflightThenResume(transfer, params);
    return .pending;
}

fn cacheKey(allocator: Allocator, origin: []const u8, method: Method, url: []const u8) ![]const u8 {
    return std.mem.join(allocator, "\x00", &.{ origin, @tagName(method), url });
}

// Every non-safelisted author header must be named in Allow-Headers.
fn headersAllowed(transfer: *Transfer, allow_headers: []const u8, credentialed: bool) bool {
    const wildcard = !credentialed and listContains(allow_headers, "*");
    for (transfer.req_headers.items) |hdr| {
        if (hdr.source != .author) continue;
        if (safelistedRequestHeader(hdr.name, hdr.value)) continue;
        if (wildcard) continue;
        if (!listContains(allow_headers, hdr.name)) {
            log.warn(.http, "cors blocked", .{
                .url = transfer.req.url,
                .reason = "header not allowed",
                .header = hdr.name,
            });
            return false;
        }
    }
    return true;
}

// The Access-Control-Request-Headers value: sorted, lowercased, comma-joined.
fn requestHeadersList(allocator: Allocator, transfer: *Transfer) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (transfer.req_headers.items) |hdr| {
        if (hdr.source != .author) continue;
        if (safelistedRequestHeader(hdr.name, hdr.value)) continue;
        const lower = try std.ascii.allocLowerString(allocator, hdr.name);
        for (names.items) |n| {
            if (std.mem.eql(u8, n, lower)) break;
        } else try names.append(allocator, lower);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return std.mem.join(allocator, ",", names.items);
}

// A parked transfer is dying out-of-band — unlink it so the preflight
// resolution doesn't touch freed memory. Mirrors RobotsGate.remove.
pub fn remove(self: *Cors, transfer: *Transfer) void {
    var it = self.pending.valueIterator();
    while (it.next()) |waiting| {
        for (waiting.items, 0..) |t, i| {
            if (t == transfer) {
                _ = waiting.swapRemove(i);
                return;
            }
        }
    }
}

fn preflightThenResume(self: *Cors, transfer: *Transfer, params: Params) !void {
    if (self.pending.getPtr(transfer.req.url)) |waiting| {
        try waiting.append(self.allocator, transfer);
        transfer.park(.cors);
        return;
    }

    const client = transfer.client;

    // Same ownership rule as RobotsGate: the context, its key and the
    // captured headers live on their own pooled arena, because any waiter
    // (this one included) can be aborted while the preflight is in flight.
    const arena = try client.arena_pool.acquire(.small, "Cors.Preflight");
    errdefer arena.release();

    const owned_url = try arena.dupeZ(u8, transfer.req.url);
    const ctx = try arena.create(Preflight);
    ctx.* = .{
        .gate = self,
        .arena = arena,
        .url = owned_url,
        .origin = try arena.dupe(u8, params.origin),
    };

    var waiting: std.ArrayList(*Transfer) = .empty;
    try waiting.append(self.allocator, transfer);
    errdefer waiting.deinit(self.allocator);

    try self.pending.putNoClobber(self.allocator, owned_url, waiting);
    errdefer _ = self.pending.remove(owned_url);

    const request_headers = try requestHeadersList(arena.allocator(), transfer);
    const request_method = @tagName(transfer.req.method);

    transfer.park(.cors);
    errdefer transfer.unpark();

    log.debug(.http, "cors preflight", .{ .url = owned_url, .method = request_method });

    const pf = try client.newRequest(.{
        .url = owned_url,
        .method = .OPTIONS,
        .internal = true,
        .resource_type = .fetch,
        .frame_id = transfer.req.frame_id,
        .document_frame_id = transfer.req.document_frame_id,
        .loader_id = transfer.req.loader_id,
        .notification = transfer.req.notification,
        .cookie_jar = null,
        .cookie_origin = owned_url,
        .ctx = ctx,
        .header_callback = Preflight.headerCallback,
        .done_callback = Preflight.doneCallback,
        .error_callback = Preflight.errorCallback,
        .shutdown_callback = Preflight.shutdownCallback,
    }, null);

    {
        errdefer pf.deinit();
        try pf.setHeader("Origin", params.origin, .{});
        try pf.setHeader("Access-Control-Request-Method", request_method, .{});
        if (request_headers.len > 0) {
            try pf.setHeader("Access-Control-Request-Headers", request_headers, .{});
        }
    }

    // From here the preflight owns the pending entry and the arena; a
    // submit failure fires error_callback (possibly synchronously) which
    // resolves the waiters and releases the arena.
    pf.submit() catch {};
}

fn store(self: *Cors, key: []const u8, grant: Grant) !void {
    if (self.cache.count() >= max_cache) {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.allow_headers);
        }
        self.cache.clearRetainingCapacity();
    }

    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    const owned_headers = try self.allocator.dupe(u8, grant.allow_headers);
    errdefer self.allocator.free(owned_headers);

    const gop = try self.cache.getOrPut(self.allocator, owned_key);
    if (gop.found_existing) {
        self.allocator.free(owned_key);
        self.allocator.free(gop.value_ptr.allow_headers);
    }
    gop.value_ptr.* = .{
        .expires_at = grant.expires_at,
        .allow_headers = owned_headers,
        .credentialed = grant.credentialed,
    };
}

// Hand every waiter its verdict. `ctx` is null when the preflight never
// produced a response (network error / shutdown) — fail closed.
fn flushPending(self: *Cors, ctx: *Preflight, ok: bool) void {
    var queued = self.pending.fetchRemove(ctx.url) orelse return;
    defer queued.value.deinit(self.allocator);

    for (queued.value.items) |transfer| {
        transfer.unpark();

        const params = transfer.req.cors.?;
        const allowed = ok and
            allowGrantsOrigin(ctx, params) and
            methodAllowed(ctx.allow_methods, transfer.req.method, params.credentialed) and
            headersAllowed(transfer, ctx.allow_headers, params.credentialed);

        if (!allowed) {
            log.warn(.http, "cors preflight denied", .{ .url = transfer.req.url, .status = ctx.status });
            transfer.failAsync(error.CorsBlocked);
            continue;
        }

        if (ctx.max_age > 0) {
            const key = cacheKey(transfer.arena.allocator(), params.origin, transfer.req.method, transfer.req.url) catch null;
            if (key) |k| {
                self.store(k, .{
                    .expires_at = lp.datetime.timestamp(.boot) + ctx.max_age,
                    .allow_headers = ctx.allow_headers,
                    .credentialed = params.credentialed,
                }) catch {};
            }
        }

        transfer.client.resumeAfterCors(transfer) catch |e| {
            transfer.abortPipelineError(e);
        };
    }
}

fn allowGrantsOrigin(ctx: *const Preflight, params: Params) bool {
    const allowed = ctx.allow_origin orelse return false;
    if (std.mem.eql(u8, allowed, "*")) {
        return !params.credentialed;
    }
    if (!std.mem.eql(u8, allowed, params.origin)) return false;
    if (params.credentialed) {
        const creds = ctx.allow_credentials orelse return false;
        return std.mem.eql(u8, creds, "true");
    }
    return true;
}

fn methodAllowed(allow_methods: []const u8, method: Method, credentialed: bool) bool {
    if (simpleMethod(method)) return true;
    if (!credentialed and listContains(allow_methods, "*")) return true;
    return listContains(allow_methods, @tagName(method));
}

const Preflight = struct {
    gate: *Cors,
    arena: *lp.Arena,
    url: [:0]const u8,
    origin: []const u8,
    status: u16 = 0,
    allow_origin: ?[]const u8 = null,
    allow_credentials: ?[]const u8 = null,
    allow_methods: []const u8 = "",
    allow_headers: []const u8 = "",
    max_age: u64 = 0,

    fn headerCallback(transfer: *Transfer) anyerror!Transfer.HeaderResult {
        const self: *Preflight = @ptrCast(@alignCast(transfer.req.ctx));
        const allocator = self.arena.allocator();

        self.status = transfer.responseStatus() orelse 0;

        var it = transfer.responseHeaderIterator();
        while (it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-origin")) {
                self.allow_origin = try allocator.dupe(u8, hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-credentials")) {
                self.allow_credentials = try allocator.dupe(u8, hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-methods")) {
                self.allow_methods = try allocator.dupe(u8, hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-allow-headers")) {
                self.allow_headers = try allocator.dupe(u8, hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "access-control-max-age")) {
                self.max_age = std.fmt.parseInt(u64, std.mem.trim(u8, hdr.value, " \t"), 10) catch 0;
            }
        }
        return .proceed;
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *Preflight = @ptrCast(@alignCast(ctx_ptr));
        const gate = self.gate;
        const arena = self.arena;
        gate.flushPending(self, self.status >= 200 and self.status < 300);
        arena.release();
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *Preflight = @ptrCast(@alignCast(ctx_ptr));
        log.warn(.http, "cors preflight failed", .{ .url = self.url, .err = err });
        const gate = self.gate;
        const arena = self.arena;
        gate.flushPending(self, false);
        arena.release();
    }

    // Client-wide teardown: every waiter is being killed by the same loop.
    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *Preflight = @ptrCast(@alignCast(ctx_ptr));
        const gate = self.gate;
        const arena = self.arena;
        if (gate.pending.fetchRemove(self.url)) |*pending| {
            var value = pending.value;
            value.deinit(gate.allocator);
        }
        arena.release();
    }
};

const testing = @import("../testing.zig");

test "WebApi: cors" {
    try testing.htmlRunner("cors/cors.html", .{});
}

test "Cors: safelisted request headers" {
    try testing.expectEqual(true, safelistedRequestHeader("Accept", "*/*"));
    try testing.expectEqual(true, safelistedRequestHeader("content-type", "text/plain; charset=utf-8"));
    try testing.expectEqual(false, safelistedRequestHeader("content-type", "application/json"));
    try testing.expectEqual(true, safelistedRequestHeader("Range", "bytes=0-99"));
    try testing.expectEqual(false, safelistedRequestHeader("X-Custom", "1"));
}

test "Cors: list membership" {
    try testing.expectEqual(true, listContains("GET, PUT, DELETE", "put"));
    try testing.expectEqual(false, listContains("GET, PUT", "patch"));
    try testing.expectEqual(false, listContains("", "get"));
}

test "Cors: expose filter" {
    const credentialed: Expose = .{ .list = "*", .credentialed = true };
    try testing.expectEqual(false, credentialed.allows("x-total"));
    try testing.expectEqual(true, credentialed.allows("content-type"));

    const wildcard: Expose = .{ .list = "*", .credentialed = false };
    try testing.expectEqual(true, wildcard.allows("x-total"));

    const named: Expose = .{ .list = "x-total, x-page", .credentialed = false };
    try testing.expectEqual(true, named.allows("X-Total"));
    try testing.expectEqual(false, named.allows("x-secret"));
}

test "Cors: preflight method check" {
    try testing.expectEqual(true, methodAllowed("", .POST, false));
    try testing.expectEqual(false, methodAllowed("GET", .PUT, false));
    try testing.expectEqual(true, methodAllowed("GET, PUT", .PUT, false));
    try testing.expectEqual(true, methodAllowed("*", .PUT, false));
    try testing.expectEqual(false, methodAllowed("*", .PUT, true));
}
