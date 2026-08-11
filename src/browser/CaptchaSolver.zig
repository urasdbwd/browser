// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Outsourced reCAPTCHA/hCaptcha solving: describe a widget to a third-party
// service, get a response token back, write it into the page. Turnstile stays
// local and click-only in `Turnstile.zig`.
//
// CapSolver, 2Captcha and Anti-Captcha all expose `createTask` /
// `getTaskResult`. Their task names and a few provider-specific fields differ.

const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const Frame = @import("Frame.zig");
const Session = @import("Session.zig");
const js = @import("js/js.zig");

const log = lp.log;

/// How often to ask the service whether a task is done. Services bill per
/// solve rather than per poll, but they rate-limit impatient clients.
pub const poll_interval_ms: u32 = 3_000;

/// A hiccup on `createTask` is worth one fast retry; anything longer stalls
/// the page, since these calls run on the browser's own thread.
const retry_policy: zenai.retry.RetryPolicy = .{
    .max_attempts = 2,
    .initial_backoff_ms = 500,
    .max_backoff_ms = 500,
};

pub const Kind = enum {
    recaptcha_v2,
    hcaptcha,
};

pub const Provider = enum {
    capsolver,
    twocaptcha,
    anticaptcha,

    fn baseUrl(self: Provider) []const u8 {
        return switch (self) {
            .capsolver => "https://api.capsolver.com",
            .twocaptcha => "https://api.2captcha.com",
            .anticaptcha => "https://api.anti-captcha.com",
        };
    }

    fn taskType(self: Provider, kind: Kind) ?[]const u8 {
        return switch (kind) {
            .hcaptcha => switch (self) {
                // CapSolver no longer documents an hCaptcha task. Prefer a
                // configured provider that has an explicit contract for it.
                .capsolver => null,
                .twocaptcha, .anticaptcha => "HCaptchaTaskProxyless",
            },
            .recaptcha_v2 => switch (self) {
                .capsolver => "ReCaptchaV2TaskProxyLess",
                .twocaptcha, .anticaptcha => "RecaptchaV2TaskProxyless",
            },
        };
    }

    fn supports(self: Provider, kind: Kind) bool {
        return self.taskType(kind) != null;
    }
};

pub const Credentials = struct {
    provider: Provider,
    api_key: []const u8,
    /// Overrides the provider's host. Only the tests set it, to reach a local
    /// stand-in rather than a service that bills per request.
    base_url: ?[]const u8 = null,
};

const env_vars = [_]struct { provider: Provider, name: [:0]const u8 }{
    .{ .provider = .capsolver, .name = "CAPSOLVER_API_KEY" },
    .{ .provider = .twocaptcha, .name = "TWOCAPTCHA_API_KEY" },
    .{ .provider = .anticaptcha, .name = "ANTICAPTCHA_API_KEY" },
};

/// The first solver service with a key in the environment, or null.
///
/// A key in the environment is the whole opt-in. Every solve costs real
/// money, so there is deliberately no flag that picks a service without one,
/// and the key never lands in argv where `ps` would show it — the same
/// convention `tools.zig` uses for BRAVE_API_KEY / TAVILY_API_KEY.
pub fn credentials() ?Credentials {
    for (env_vars) |entry| {
        const value = std.c.getenv(entry.name) orelse continue;
        const api_key = std.mem.span(value);
        if (api_key.len == 0) continue;
        return .{ .provider = entry.provider, .api_key = api_key };
    }
    return null;
}

/// First configured service whose documented API supports `kind`.
pub fn credentialsFor(kind: Kind) ?Credentials {
    for (env_vars) |entry| {
        if (entry.provider.supports(kind) == false) continue;
        const value = std.c.getenv(entry.name) orelse continue;
        const api_key = std.mem.span(value);
        if (api_key.len == 0) continue;
        return .{ .provider = entry.provider, .api_key = api_key };
    }
    return null;
}

pub const Widget = struct {
    kind: Kind,
    sitekey: []const u8,
    /// Optional provider action; empty when the page omits it.
    action: []const u8 = "",
    /// The page the widget sits on. The service signs the token against it,
    /// so a wrong URL yields a token the site rejects.
    url: []const u8,
};

// Read-only. Writes nothing to the DOM, so the page cannot see that we
// looked — same constraint `Turnstile.token_script` works under.
//
// ponytail: only reads sitekeys the page left somewhere readable —
// `data-sitekey`, or a reCAPTCHA/hCaptcha iframe query parameter.
const detect_script =
    \\(() => {
    \\  try {
    \\    const fromAttr = (sel, kind) => {
    \\      for (const el of document.querySelectorAll(sel)) {
    \\        const k = el.getAttribute('data-sitekey');
    \\        if (k) return { kind: kind, sitekey: k, action: el.getAttribute('data-action') || '' };
    \\      }
    \\      return null;
    \\    };
    \\    const fromIframe = () => {
    \\      for (const f of document.querySelectorAll('iframe[src]')) {
    \\        // `.src` not the attribute: a relative src still has to match.
    \\        const src = f.src || f.getAttribute('src') || '';
    \\        const kind = src.indexOf('hcaptcha.com') !== -1 ? 'hcaptcha'
    \\                   : (src.indexOf('/recaptcha/') !== -1 ? 'recaptcha_v2' : null);
    \\        if (!kind) continue;
    \\        const m = src.match(/[?&#](?:k|sitekey)=([^&#]+)/);
    \\        if (m) return { kind: kind, sitekey: decodeURIComponent(m[1]), action: '' };
    \\      }
    \\      return null;
    \\    };
    \\    const w = fromAttr('.h-captcha', 'hcaptcha')
    \\           || fromAttr('.g-recaptcha', 'recaptcha_v2')
    \\           || fromIframe();
    \\    return w ? JSON.stringify(w) : '';
    \\  } catch (e) { return ''; }
    \\})()
;

/// First solvable widget in the session, or null. Everything returned is
/// duped into `allocator`, which must outlive the solve.
pub fn detect(session: *Session, allocator: std.mem.Allocator) ?Widget {
    for (session.pages.items) |page| {
        if (page.replacement != null) continue;
        if (detectFrame(&page.frame, allocator)) |w| return w;
    }
    return null;
}

fn detectFrame(frame: *Frame, allocator: std.mem.Allocator) ?Widget {
    if (frameWidget(frame, allocator)) |w| return w;
    for (frame.child_frames.items) |child| {
        if (detectFrame(child, allocator)) |w| return w;
    }
    return null;
}

fn frameWidget(frame: *Frame, allocator: std.mem.Allocator) ?Widget {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const v = ls.local.exec(detect_script, "captcha_detect") catch return null;
    const raw = v.toStringSlice() catch return null;
    if (raw.len == 0) return null;

    const Found = struct { kind: []const u8, sitekey: []const u8, action: []const u8 };
    const parsed = std.json.parseFromSlice(Found, allocator, raw, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    if (parsed.value.sitekey.len == 0) return null;
    const kind = std.meta.stringToEnum(Kind, parsed.value.kind) orelse return null;

    // Escape the local scope's arena and the parse arena both; the caller
    // holds this across the whole solve.
    return .{
        .kind = kind,
        .sitekey = allocator.dupe(u8, parsed.value.sitekey) catch return null,
        .action = allocator.dupe(u8, parsed.value.action) catch return null,
        .url = allocator.dupe(u8, frame.url) catch return null,
    };
}

/// Where a solved token belongs. The widget creates these fields when it
/// renders, so they exist by the time we have a token for them.
fn responseFields(kind: Kind) []const u8 {
    return switch (kind) {
        .recaptcha_v2 => "['#g-recaptcha-response','[name=\"g-recaptcha-response\"]','textarea[id^=\"g-recaptcha-response\"]']",
        .hcaptcha => "['[name=\"h-captcha-response\"]','[name=\"g-recaptcha-response\"]']",
    };
}

fn hostSelector(kind: Kind) []const u8 {
    return switch (kind) {
        .recaptcha_v2 => "'.g-recaptcha'",
        .hcaptcha => "'.h-captcha'",
    };
}

// Filling the response field is what the site's form submit reads; firing
// `data-callback` is what a site that gates a button on the callback reads.
// A real solve does both, so we do both.
//
// ponytail: does not walk `___grecaptcha_cfg.clients` for callbacks
// registered through `grecaptcha.render()` rather than `data-callback`. Add
// that traversal if a site accepts the token but never enables its button.
const inject_body =
    \\  try {
    \\    let n = 0;
    \\    for (const sel of fields) {
    \\      for (const el of document.querySelectorAll(sel)) {
    \\        el.value = t;
    \\        if (el.tagName === 'TEXTAREA') el.textContent = t;
    \\        n++;
    \\      }
    \\    }
    \\    for (const el of document.querySelectorAll(host)) {
    \\      const name = el.getAttribute('data-callback');
    \\      if (!name) continue;
    \\      const fn = window[name];
    \\      if (typeof fn === 'function') { try { fn(t); n++; } catch (e) {} }
    \\    }
    \\    return n;
    \\  } catch (e) { return 0; }
;

/// Write `token` into the first frame that has somewhere to put it. True if
/// any field was filled or any callback fired.
pub fn inject(
    session: *Session,
    allocator: std.mem.Allocator,
    kind: Kind,
    token: []const u8,
) bool {
    // The token is service-supplied, so it goes into the script as a JSON
    // string literal rather than by concatenation.
    var quoted: std.Io.Writer.Allocating = .init(allocator);
    defer quoted.deinit();
    std.json.Stringify.value(token, .{}, &quoted.writer) catch return false;

    const script = std.mem.concat(allocator, u8, &.{
        "(() => { const t = ", quoted.written(),
        "; const fields = ",   responseFields(kind),
        "; const host = ",     hostSelector(kind),
        ";",                   inject_body,
        " })()",
    }) catch return false;
    defer allocator.free(script);

    for (session.pages.items) |page| {
        if (page.replacement != null) continue;
        if (injectFrame(&page.frame, script)) return true;
    }
    return false;
}

fn injectFrame(frame: *Frame, script: []const u8) bool {
    if (frameInject(frame, script)) return true;
    for (frame.child_frames.items) |child| {
        if (injectFrame(child, script)) return true;
    }
    return false;
}

fn frameInject(frame: *Frame, script: []const u8) bool {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const v = ls.local.exec(script, "captcha_inject") catch return false;
    const filled = v.toU32() catch return false;
    return filled > 0;
}

/// One in-flight solve. `init` does no I/O, so the struct is safe to move
/// until `start` runs; nothing holds a pointer into it before then.
pub const Job = struct {
    allocator: std.mem.Allocator,
    provider: Provider,
    api_key: []const u8,
    base_url: []const u8,
    kind: Kind,
    http_client: std.http.Client,
    task_id: ?TaskId = null,
    // Read by `zenai.http.fetchJsonWithRetry` through the error-handler
    // interface it expects; see `setErrorDetail`.
    last_error_status: ?u10 = null,
    last_error_body: ?[]const u8 = null,

    // Anti-Captcha issues integer task ids, CapSolver string uuids. Whichever
    // came back has to go out again with the same JSON type.
    const TaskId = union(enum) {
        int: i64,
        str: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, creds: Credentials, kind: Kind) Job {
        return .{
            .allocator = allocator,
            .provider = creds.provider,
            .api_key = creds.api_key,
            .base_url = creds.base_url orelse creds.provider.baseUrl(),
            .kind = kind,
            .http_client = .{ .allocator = allocator, .io = lp.io },
        };
    }

    pub fn deinit(self: *Job) void {
        self.http_client.deinit();
        if (self.last_error_body) |b| self.allocator.free(b);
    }

    pub fn setErrorDetail(self: *Job, status_code: u10, body: []const u8) void {
        self.last_error_status = status_code;
        if (self.last_error_body) |old| self.allocator.free(old);
        self.last_error_body = if (body.len == 0) null else self.allocator.dupe(u8, body) catch null;
    }

    const Payload = struct {
        clientKey: []const u8,
        task: Task,

        const Task = struct {
            type: []const u8,
            websiteURL: []const u8,
            websiteKey: []const u8,
            action: ?[]const u8 = null,
        };
    };

    /// Hand the widget to the service. Blocks for one round trip.
    pub fn start(self: *Job, widget: Widget) !void {
        const allocator = self.allocator;

        const url = try std.fmt.allocPrint(allocator, "{s}/createTask", .{self.base_url});
        defer allocator.free(url);

        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        try self.writeCreatePayload(&payload.writer, widget);

        var response = try zenai.http.fetchJsonWithRetry(allocator, &self.http_client, retry_policy, .{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload.written(),
            .headers = .{ .content_type = .{ .override = "application/json" } },
        }, std.json.Value, self);
        defer response.deinit();

        const obj = try checkApiError(response.value);
        const raw = obj.get("taskId") orelse return error.NoTaskId;
        self.task_id = switch (raw) {
            .integer => |i| .{ .int = i },
            .string => |s| .{ .str = try allocator.dupe(u8, s) },
            else => return error.NoTaskId,
        };
    }

    fn writeCreatePayload(self: *const Job, writer: *std.Io.Writer, widget: Widget) !void {
        const action = if (widget.action.len == 0) null else widget.action;
        std.json.Stringify.value(Payload{
            .clientKey = self.api_key,
            .task = .{
                .type = self.provider.taskType(widget.kind) orelse return error.UnsupportedCaptcha,
                .websiteURL = widget.url,
                .websiteKey = widget.sitekey,
                .action = action,
            },
        }, .{ .emit_null_optional_fields = false }, writer) catch return error.OutOfMemory;
    }

    /// The solved token, or null while the service is still working. Blocks
    /// for one round trip; call it no more often than `poll_interval_ms`.
    pub fn poll(self: *Job) !?[]const u8 {
        const allocator = self.allocator;
        const task_id = self.task_id orelse return error.NotStarted;

        const url = try std.fmt.allocPrint(allocator, "{s}/getTaskResult", .{self.base_url});
        defer allocator.free(url);

        var payload: std.Io.Writer.Allocating = .init(allocator);
        defer payload.deinit();
        switch (task_id) {
            .int => |v| try self.writeQuery(&payload.writer, v),
            .str => |v| try self.writeQuery(&payload.writer, v),
        }

        // The 3s poll loop is the retry; a backoff sleep here would only park
        // the page for longer than the next poll would have waited anyway.
        var response = try zenai.http.fetchJsonWithRetry(allocator, &self.http_client, zenai.retry.RetryPolicy.disabled, .{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload.written(),
            .headers = .{ .content_type = .{ .override = "application/json" } },
        }, std.json.Value, self);
        defer response.deinit();

        const obj = try checkApiError(response.value);
        const status = obj.get("status") orelse return null;
        switch (status) {
            .string => |s| if (std.mem.eql(u8, s, "ready") == false) return null,
            else => return null,
        }

        const solution = switch (obj.get("solution") orelse return error.NoSolution) {
            .object => |o| o,
            else => return error.NoSolution,
        };
        // hCaptcha commonly comes back as `token`, reCAPTCHA as
        // `gRecaptchaResponse`. Take whichever the service returned.
        const token = solution.get("token") orelse
            solution.get("gRecaptchaResponse") orelse
            return error.NoSolution;
        return switch (token) {
            .string => |s| try allocator.dupe(u8, s),
            else => error.NoSolution,
        };
    }

    fn writeQuery(self: *const Job, w: *std.Io.Writer, task_id: anytype) !void {
        std.json.Stringify.value(.{
            .clientKey = self.api_key,
            .taskId = task_id,
        }, .{}, w) catch return error.OutOfMemory;
    }
};

/// Unwrap the envelope every endpoint shares: a non-zero `errorId` means the
/// service refused, and the reason is worth logging — a bad key or an empty
/// balance looks exactly like a slow solve otherwise.
fn checkApiError(value: std.json.Value) !std.json.ObjectMap {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.BadResponse,
    };
    const code = switch (obj.get("errorId") orelse return obj) {
        .integer => |i| i,
        else => 0,
    };
    if (code == 0) return obj;

    const description = if (obj.get("errorDescription")) |d| switch (d) {
        .string => |s| s,
        else => "",
    } else "";
    log.warn(.browser, "captcha service refused", .{ .code = code, .description = description });
    return error.SolverRejected;
}

const testing = @import("../testing.zig");

test "CaptchaSolver: detects outsourced widget types by data-sitekey" {
    const cases = [_]struct { file: []const u8, kind: Kind, sitekey: []const u8 }{
        .{ .file = "turnstile/sitekey_only.html", .kind = .hcaptcha, .sitekey = "10000000-ffff-ffff-ffff-000000000001" },
        .{ .file = "captcha/recaptcha.html", .kind = .recaptcha_v2, .sitekey = "6Le-wvkSAAAAAPBMRTvw0Q4Muexq9bi0DJwx_mJ-" },
    };

    // `pageTest` takes its path at comptime, so the table has to unroll.
    inline for (cases) |case| {
        const page = try testing.pageTest(case.file, .{});
        defer page.close();

        const widget = detect(page.session, testing.arena_allocator) orelse return error.NoWidgetDetected;
        try testing.expectEqual(case.kind, widget.kind);
        try testing.expectString(case.sitekey, widget.sitekey);
    }
}

test "CaptchaSolver: leaves Turnstile to the local click solver" {
    const page = try testing.pageTest("turnstile/widget.html", .{});
    defer page.close();

    try testing.expectEqual(true, detect(page.session, testing.arena_allocator) == null);
}

test "CaptchaSolver: reads a reCAPTCHA sitekey out of the iframe url" {
    const page = try testing.pageTest("captcha/recaptcha_iframe.html", .{});
    defer page.close();

    const widget = detect(page.session, testing.arena_allocator) orelse return error.NoWidgetDetected;
    try testing.expectEqual(Kind.recaptcha_v2, widget.kind);
    try testing.expectString("6LcIframeKeyAAAAAExampleValue1234567890", widget.sitekey);
}

test "CaptchaSolver: ignores a page with no captcha" {
    const page = try testing.pageTest("runner/runner1.html", .{});
    defer page.close();

    try testing.expectEqual(true, detect(page.session, testing.arena_allocator) == null);
}

test "CaptchaSolver: injection fills the response field and fires the callback" {
    const page = try testing.pageTest("captcha/recaptcha.html", .{});
    defer page.close();

    try testing.expectEqual(true, inject(page.session, testing.arena_allocator, .recaptcha_v2, "SOLVED-TOKEN-123"));

    var runner = page.session.runner(.{});
    try runner.waitForScript(
        page.frame_id,
        "document.getElementById('g-recaptcha-response').value === 'SOLVED-TOKEN-123'",
        10,
    );
    // The site's own callback ran with the token, not just the hidden field.
    try runner.waitForScript(page.frame_id, "window.__captcha_callback === 'SOLVED-TOKEN-123'", 10);
}

test "CaptchaSolver: CapSolver spells the reCAPTCHA task type its own way" {
    try testing.expectString("ReCaptchaV2TaskProxyLess", Provider.capsolver.taskType(.recaptcha_v2).?);
    try testing.expectString("RecaptchaV2TaskProxyless", Provider.anticaptcha.taskType(.recaptcha_v2).?);
    try testing.expectEqual(true, Provider.capsolver.taskType(.hcaptcha) == null);
}

/// Point a job at the local stand-in for `vendor` instead of a billed service.
fn testJob(vendor: []const u8, provider: Provider) !Job {
    const base = try std.fmt.allocPrint(
        testing.arena_allocator,
        "http://127.0.0.1:9582/captcha/{s}",
        .{vendor},
    );
    return Job.init(testing.arena_allocator, .{
        .provider = provider,
        .api_key = "test-client-key",
        .base_url = base,
    }, .recaptcha_v2);
}

const test_widget: Widget = .{
    .kind = .recaptcha_v2,
    .sitekey = "6Le-wvkSAAAAAPBMRTvw0Q4Muexq9bi0DJwx_mJ-",
    .url = "https://example.com/login",
};

test "CaptchaSolver: one client speaks all three services' response shapes" {
    // The whole reason there is one client and not three. Each stand-in
    // replays its vendor's real envelope, including the task-id JSON type it
    // expects back and the key it hides the token under.
    const cases = [_]struct { vendor: []const u8, provider: Provider, token: []const u8 }{
        .{ .vendor = "anticaptcha", .provider = .anticaptcha, .token = "ANTICAPTCHA-TOKEN-0001" },
        .{ .vendor = "capsolver", .provider = .capsolver, .token = "CAPSOLVER-TOKEN-0002" },
        .{ .vendor = "twocaptcha", .provider = .twocaptcha, .token = "TWOCAPTCHA-TOKEN-0003" },
    };

    for (cases) |case| {
        var job = try testJob(case.vendor, case.provider);
        defer job.deinit();

        try job.start(test_widget);
        const token = (try job.poll()) orelse return error.ServiceReturnedNoToken;
        try testing.expectString(case.token, token);
    }
}

test "CaptchaSolver: a uuid task id survives the round trip as a uuid" {
    // CapSolver rejects its own id if we hand it back as an integer, and
    // Anti-Captcha rejects an integer id quoted as a string. The stand-in
    // answers a mistyped id with ERROR_NO_SUCH_CAPCHA_ID, so a regression
    // here surfaces as SolverRejected rather than a wrong token.
    var uuid_job = try testJob("capsolver", .capsolver);
    defer uuid_job.deinit();
    try uuid_job.start(test_widget);
    try testing.expectString("CAPSOLVER-TOKEN-0002", (try uuid_job.poll()).?);

    var int_job = try testJob("twocaptcha", .twocaptcha);
    defer int_job.deinit();
    try int_job.start(test_widget);
    try testing.expectString("TWOCAPTCHA-TOKEN-0003", (try int_job.poll()).?);
}

test "CaptchaSolver: a service still working reports no token yet" {
    var job = try testJob("pending", .twocaptcha);
    defer job.deinit();

    try job.start(test_widget);
    // `processing` is not a failure and not a token — the caller polls again.
    try testing.expectEqual(true, (try job.poll()) == null);
}

test "CaptchaSolver: a rejected key fails loudly instead of waiting out the budget" {
    var job = try testJob("badkey", .anticaptcha);
    defer job.deinit();

    try testing.expectError(error.SolverRejected, job.start(test_widget));
}

test "CaptchaSolver: polling before the task exists is an error, not a hang" {
    var job = try testJob("twocaptcha", .twocaptcha);
    defer job.deinit();

    try testing.expectError(error.NotStarted, job.poll());
}
