// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const Element = @import("../browser/webapi/Element.zig");
const Event = @import("../browser/webapi/Event.zig");
const Selector = @import("../browser/webapi/selector/Selector.zig");

const LiveSession = @This();

const SnapshotCursor = struct {
    page_incarnation: u64 = 0,
    version: usize = 0,
    base: ?[]u8 = null,

    fn changed(
        self: SnapshotCursor,
        page: *const lp.Page,
        base: []const u8,
    ) bool {
        if (self.page_incarnation != page.incarnation or
            self.version != page.snapshot_version or
            self.page_incarnation == 0)
        {
            return true;
        }
        return if (self.base) |previous| !std.mem.eql(u8, previous, base) else true;
    }

    fn mark(
        self: *SnapshotCursor,
        allocator: std.mem.Allocator,
        page: *const lp.Page,
        base: []const u8,
    ) !void {
        if (self.base == null or !std.mem.eql(u8, self.base.?, base)) {
            const copy = try allocator.dupe(u8, base);
            if (self.base) |previous| allocator.free(previous);
            self.base = copy;
        }
        self.page_incarnation = page.incarnation;
        self.version = page.snapshot_version;
    }

    fn deinit(self: *SnapshotCursor, allocator: std.mem.Allocator) void {
        if (self.base) |base| allocator.free(base);
        self.* = .{};
    }
};

pub const Action = enum {
    open,
    snapshot,
    navigate,
    back,
    forward,
    reload,
    click,
    animationend,
    fill,
    press,
    keydown,
    keyup,
    mousedown,
    mouseup,
    mousemove,
    mouseover,
    mouseout,
    mouseenter,
    mouseleave,
    contextmenu,
    dblclick,
    wheel,
    scroll,
    close,
};

pub const Command = struct {
    id: u32,
    type: Action,
    url: ?[]const u8 = null,
    selector: ?[]const u8 = null,
    target: ?Target = null,
    value: ?[]const u8 = null,
    key: ?[]const u8 = null,
    code: ?[]const u8 = null,
    location: u32 = 0,
    repeat: bool = false,
    x: ?i32 = null,
    y: ?i32 = null,
    button: i32 = 0,
    buttons: u16 = 0,
    detail: u32 = 1,
    delta_x: f64 = 0,
    delta_y: f64 = 0,
    alt_key: bool = false,
    ctrl_key: bool = false,
    meta_key: bool = false,
    shift_key: bool = false,
    // See RenderRequest.wait_ms: with no explicit wait_until the settle target
    // is `.done`, which a page with any background network never reaches, so
    // this budget gets burned in full on every navigation.
    wait_ms: u32 = 1_500,
    wait_until: ?lp.Config.WaitUntil = null,
    width: u32 = 1280,
    height: u32 = 720,
    snapshot: bool = true,
    direct_resources: DirectResources = .off,
};

pub const Target = struct {
    version: []const u8,
    id: u32,
};

/// Whether the viewer's own browser may fetch the page's stylesheets, images,
/// fonts and media straight from their origins.
///
/// With it off, the render CSP allows only `data:` and `blob:`, so every
/// external subresource is blocked and the page renders unstyled and
/// imageless. With it on, the page looks right — but the origin then sees two
/// different clients for one page load: Lightpanda's IP and TLS fingerprint
/// fetched the document, the end user's fetches the assets. To anything doing
/// bot detection that mismatch is a strong signal, and it silently undermines
/// the stealth surface the rest of the browser works to keep intact. That is a
/// per-deployment call, not a default, which is why this is an explicit
/// three-state option rather than a bool with a quiet answer.
pub const DirectResources = enum {
    /// Off when `--stealth` is set, on otherwise: an operator who is not hiding
    /// has no fingerprint split to lose. Note this is the *inverse* of
    /// `--solve_captchas auto`, which turns itself on under stealth.
    auto,
    on,
    off,

    pub fn enabled(self: DirectResources, config: *const lp.Config) bool {
        return switch (self) {
            .on => true,
            .off => false,
            .auto => !config.stealth(),
        };
    }
};

pub const Outcome = struct {
    id: u32,
    snapshot: bool = false,
    closed: bool = false,
    // Set when a command succeeded but produced no usable snapshot (an
    // oversized document). The session stays open and the client shows a
    // notice rather than being disconnected mid-browse.
    warning: ?[]const u8 = null,
    target_version: ?[16]u8 = null,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    /// Turnstile solve outcome for the document currently loaded
    /// (`no_widget` / `solved` / `timeout`), or null when solving is off.
    /// Set by navigation and carried until the next one — it describes the
    /// page, so a `click` that does not navigate keeps reporting it.
    turnstile: ?[]const u8 = null,
};

/// Surfaced to the client when a document is too large to serialize. A notice
/// page has no `data-lp-t-*` markers, so sending one as a snapshot would fail
/// the client's hydration check and close the socket.
pub const oversized_document_warning = "document too large to render; showing the previous view";

pub const ProcessError = error{
    BadRequest,
    NotOwner,
    NodeNotFound,
    StaleTarget,
    Timeout,
    NavigationFailed,
    InternalError,
};

const TargetTable = struct {
    page_incarnation: u64 = 0,
    dom_version: usize = 0,
    generation: u64 = 0,
    /// Set when this snapshot's id->element mapping differs from the one the
    /// client last saw under the same generation. Targets are refused while it
    /// is set and the next snapshot rotates the generation.
    remapped: bool = false,
    elements: std.ArrayList(*Element) = .empty,

    /// The generation is baked into the `data-lp-t-*` attribute *name* on every
    /// element, so rotating it rewrites the whole document and costs the delta
    /// encoder its shared prefix. It only has to rotate when the id->element
    /// mapping changes; a page that only animates styles keeps the same mapping
    /// frame after frame and so keeps the same generation.
    fn boundTo(self: *const TargetTable, page: *const lp.Page) bool {
        return self.page_incarnation == page.incarnation and
            !self.remapped and
            self.page_incarnation != 0 and
            self.generation != 0;
    }

    fn deinit(self: *TargetTable, allocator: std.mem.Allocator) void {
        self.elements.deinit(allocator);
        self.* = .{};
    }
};

const NavigationAttempt = struct {
    frame_id: u32,
    failed: bool = false,

    fn onFailed(ctx: *anyopaque, event: *const lp.Notification.FrameNavigateFailed) !void {
        const self: *NavigationAttempt = @ptrCast(@alignCast(ctx));
        if (event.frame_id == self.frame_id) self.failed = true;
    }
};

const default_navigation_wait: lp.Config.WaitUntil = .domcontentloaded;

// Upper bound on a `fill` command's value.
const max_fill_value = 64 * 1024;

app: *App,
browser: *lp.Browser,
notification: *lp.Notification,
session: *lp.Session,
page: lp.Session.PageHandle,
owner: u64,
snapshot_cursor: SnapshotCursor = .{},
targets: TargetTable = .{},
next_target_generation: u64,
target_key_secret: u64,
direct_resources: bool,
turnstile: ?[]const u8 = null,

pub fn process(
    state: *?LiveSession,
    app: *App,
    browser: *lp.Browser,
    arena: std.mem.Allocator,
    owner: u64,
    body: []const u8,
    max_wait_ms: u32,
    out: *std.Io.Writer,
) ProcessError!Outcome {
    const deadline = commandDeadline(max_wait_ms);
    const command = try parseCommand(arena, body);
    return processParsed(state, app, browser, arena, owner, command, deadline, out);
}

pub fn processParsed(
    state: *?LiveSession,
    app: *App,
    browser: *lp.Browser,
    arena: std.mem.Allocator,
    owner: u64,
    command: Command,
    deadline: std.Io.Timestamp,
    out: *std.Io.Writer,
) ProcessError!Outcome {
    if (command.id == 0) return error.BadRequest;
    if (command.selector != null and command.target != null) return error.BadRequest;

    if (command.type == .open) {
        if (state.*) |*live| {
            if (live.owner != owner) return error.NotOwner;
        }
        const canonical = try validateOpen(arena, command);

        _ = try remainingCommandMs(deadline);
        if (state.*) |*live| live.deinit();
        state.* = null;

        var live = try init(app, browser, owner, canonical, command, deadline);
        errdefer live.deinit();
        _ = try remainingCommandMs(deadline);
        const warning = try live.writeSnapshot(out);
        state.* = live;
        return .{
            .id = command.id,
            .snapshot = warning == null,
            .warning = warning,
            .target_version = targetVersion(live.targets.generation),
            .can_go_back = live.session.navigation.getCanGoBack(),
            .can_go_forward = live.session.navigation.getCanGoForward(),
            .turnstile = live.turnstile,
        };
    }

    const live = if (state.*) |*value| value else return error.NotOwner;
    if (live.owner != owner) return error.NotOwner;

    switch (command.type) {
        .open => unreachable,
        .snapshot => {
            _ = try remainingCommandMs(deadline);
            _ = live.pump();
        },
        .navigate => try live.navigate(arena, command, deadline),
        .back => try live.traverse(.back, command, deadline),
        .forward => try live.traverse(.forward, command, deadline),
        .reload => try live.reload(arena, command, deadline),
        .click => try live.click(command, deadline),
        .animationend => try live.animationEnd(command, deadline),
        .fill => try live.fill(command, deadline),
        .press => try live.press(command, deadline),
        .keydown => try live.keyEvent(true, command, deadline),
        .keyup => try live.keyEvent(false, command, deadline),
        .mousedown => try live.mouseEvent(.mousedown, command, deadline),
        .mouseup => try live.mouseEvent(.mouseup, command, deadline),
        .mousemove => try live.mouseEvent(.mousemove, command, deadline),
        .mouseover => try live.mouseEvent(.mouseover, command, deadline),
        .mouseout => try live.mouseEvent(.mouseout, command, deadline),
        .mouseenter => try live.mouseEvent(.mouseenter, command, deadline),
        .mouseleave => try live.mouseEvent(.mouseleave, command, deadline),
        .contextmenu => try live.mouseEvent(.contextmenu, command, deadline),
        .dblclick => try live.mouseEvent(.dblclick, command, deadline),
        .wheel => try live.wheel(command, deadline),
        .scroll => try live.scroll(command, deadline),
        .close => {
            _ = try remainingCommandMs(deadline);
            live.deinit();
            state.* = null;
            return .{ .id = command.id, .closed = true };
        },
    }

    var warning: ?[]const u8 = null;
    const requested = command.snapshot and try live.snapshotChanged();
    if (requested) {
        _ = try remainingCommandMs(deadline);
        warning = try live.writeSnapshot(out);
    }
    // An oversized document yields a warning and no body, so the client must
    // not be told to hydrate one.
    const snapshot = requested and warning == null;
    return .{
        .id = command.id,
        .snapshot = snapshot,
        .warning = warning,
        .target_version = if (snapshot) targetVersion(live.targets.generation) else null,
        .can_go_back = live.session.navigation.getCanGoBack(),
        .can_go_forward = live.session.navigation.getCanGoForward(),
        .turnstile = live.turnstile,
    };
}

pub fn closeOwner(state: *?LiveSession, owner: u64) void {
    const live = if (state.*) |*value| value else return;
    if (live.owner != owner) return;
    live.deinit();
    state.* = null;
}

pub fn deinit(self: *LiveSession) void {
    self.targets.deinit(self.app.allocator);
    self.snapshot_cursor.deinit(self.app.allocator);
    if (self.app.config.cookieJarFile()) |cookie_jar_path| {
        lp.cookies.saveToFile(&self.session.cookie_jar, cookie_jar_path);
    }
    self.browser.closeSession();
    self.notification.deinit();
}

fn init(
    app: *App,
    browser: *lp.Browser,
    owner: u64,
    canonical: [:0]const u8,
    command: Command,
    deadline: std.Io.Timestamp,
) ProcessError!LiveSession {
    _ = try remainingCommandMs(deadline);
    const notification = lp.Notification.init(app.allocator) catch return error.InternalError;
    errdefer notification.deinit();
    _ = try remainingCommandMs(deadline);
    const session = browser.newSession(notification) catch return error.InternalError;
    errdefer browser.closeSession();
    // Interactive render sessions need frame documents even under the default
    // low-memory render profile. Workers keep their configured setting.
    session.subframe_loading_enabled = true;

    if (app.config.cookieFile()) |cookie_path| {
        lp.cookies.loadFromFile(session, cookie_path);
    }

    _ = try remainingCommandMs(deadline);
    browser.viewport_override = .{ .width = command.width, .height = command.height };
    const page = session.createPage() catch return error.InternalError;
    const frame = page.frame() orelse return error.InternalError;
    _ = try remainingCommandMs(deadline);
    const started: std.Io.Timestamp = .now(lp.io, .boot);
    frame.navigate(canonical, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch return error.NavigationFailed;

    var runner = session.runner(.{});
    runner.waitForFrame(
        page.frame_id,
        @min(command.wait_ms, try remainingCommandMs(deadline)),
        .{ .until = command.wait_until orelse default_navigation_wait },
    ) catch |err| return mapWaitError(err);
    const turnstile = solveTurnstile(app, session, command.wait_ms, started, deadline);

    var target_random: [2]u64 = undefined;
    std.Io.randomSecure(lp.io, std.mem.asBytes(&target_random)) catch
        return error.InternalError;
    var next_target_generation = target_random[0];
    if (next_target_generation == 0) next_target_generation = 1;
    var target_key_secret = target_random[1];
    if (target_key_secret == 0) target_key_secret = 1;

    return .{
        .app = app,
        .browser = browser,
        .notification = notification,
        .session = session,
        .page = page,
        .owner = owner,
        .next_target_generation = next_target_generation,
        .target_key_secret = target_key_secret,
        .direct_resources = command.direct_resources.enabled(app.config),
        .turnstile = turnstile,
    };
}

fn navigate(
    self: *LiveSession,
    arena: std.mem.Allocator,
    command: Command,
    deadline: std.Io.Timestamp,
) ProcessError!void {
    const raw_url = command.url orelse return error.BadRequest;
    const canonical = try canonicalURL(arena, raw_url);
    _ = try remainingCommandMs(deadline);
    try self.navigateAndWait(canonical, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }, command, deadline);
}

fn traverse(
    self: *LiveSession,
    direction: enum { back, forward },
    command: Command,
    deadline: std.Io.Timestamp,
) ProcessError!void {
    const navigation = self.session.navigation;
    const index = switch (direction) {
        .back => if (navigation.getCanGoBack())
            navigation._index - 1
        else
            return error.NavigationFailed,
        .forward => if (navigation.getCanGoForward())
            navigation._index + 1
        else
            return error.NavigationFailed,
    };
    const url = navigation.entries()[index]._url orelse return error.NavigationFailed;
    _ = try remainingCommandMs(deadline);
    try self.navigateAndWait(url, .{
        .reason = .history,
        .kind = .{ .traverse = index },
    }, command, deadline);
}

fn reload(
    self: *LiveSession,
    arena: std.mem.Allocator,
    command: Command,
    deadline: std.Io.Timestamp,
) ProcessError!void {
    const frame = self.page.frame() orelse return error.NavigationFailed;
    const reload_url = arena.dupeZ(u8, frame.url) catch return error.InternalError;
    const previous = frame._navigated_options;
    const body: ?[]const u8, const header: ?[:0]const u8 = blk: {
        const opts = previous orelse break :blk .{ null, null };
        break :blk .{
            if (opts.body) |value| arena.dupe(u8, value) catch return error.InternalError else null,
            if (opts.header) |value| arena.dupeZ(u8, value) catch return error.InternalError else null,
        };
    };
    _ = try remainingCommandMs(deadline);
    try self.navigateAndWait(reload_url, .{
        .reason = .address_bar,
        .kind = .reload,
        .method = if (previous) |opts| opts.method else .GET,
        .body = body,
        .header = header,
    }, command, deadline);
}

fn navigateAndWait(
    self: *LiveSession,
    url: [:0]const u8,
    opts: lp.Frame.NavigateOpts,
    command: Command,
    deadline: std.Io.Timestamp,
) ProcessError!void {
    var attempt: NavigationAttempt = .{ .frame_id = self.page.frame_id };
    self.notification.register(.frame_navigate_failed, &attempt, NavigationAttempt.onFailed) catch
        return error.InternalError;
    defer self.notification.unregister(.frame_navigate_failed, &attempt);
    const started: std.Io.Timestamp = .now(lp.io, .boot);
    self.session.navigateRoot(self.page.frame_id, url, opts) catch |err|
        return mapNavigationActionError(err);

    var runner = self.session.runner(.{});
    runner.waitForFrame(
        self.page.frame_id,
        @min(command.wait_ms, try remainingCommandMs(deadline)),
        .{ .until = command.wait_until orelse default_navigation_wait },
    ) catch |err| return mapWaitError(err);
    if (attempt.failed) return error.NavigationFailed;
    // Every navigation, not just the session's first: a live client can browse
    // into a protected page at any point.
    self.turnstile = solveTurnstile(self.app, self.session, command.wait_ms, started, deadline);
}

fn click(self: *LiveSession, command: Command, deadline: std.Io.Timestamp) ProcessError!void {
    const root = self.page.frame() orelse return error.NavigationFailed;
    const element = try self.findActionElement(root, command);
    const frame = try actionFrame(root, element);
    _ = try remainingCommandMs(deadline);
    if (command.x != null or command.y != null) {
        const x = command.x orelse return error.BadRequest;
        const y = command.y orelse return error.BadRequest;
        lp.actions.clickAt(
            element.asNode(),
            @floatFromInt(x),
            @floatFromInt(y),
            commandModifiers(command),
            frame,
        ) catch |err| return mapActionError(err);
    } else {
        lp.actions.click(element.asNode(), frame) catch |err| return mapActionError(err);
    }
    try self.finishAction(command.wait_ms, deadline);
}

fn animationEnd(self: *LiveSession, command: Command, deadline: std.Io.Timestamp) ProcessError!void {
    const root = self.page.frame() orelse return error.NavigationFailed;
    const element = try self.findActionElement(root, command);
    const frame = try actionFrame(root, element);
    _ = try remainingCommandMs(deadline);
    const event = Event.initTrusted(
        comptime .wrap("animationend"),
        .{ .bubbles = true },
        frame._page,
    ) catch return error.InternalError;
    frame._event_manager.dispatch(element.asEventTarget(), event) catch
        return error.InternalError;
    try self.finishAction(command.wait_ms, deadline);
}

fn fill(self: *LiveSession, command: Command, deadline: std.Io.Timestamp) ProcessError!void {
    const value = command.value orelse return error.BadRequest;
    // Every other client-supplied string is bounded; a textarea's worth of text
    // is generous but keeps one command from pinning arbitrary memory.
    if (value.len > max_fill_value) return error.BadRequest;
    const root = self.page.frame() orelse return error.NavigationFailed;
    const element = try self.findActionElement(root, command);
    const frame = try actionFrame(root, element);
    _ = try remainingCommandMs(deadline);
    lp.actions.fill(element.asNode(), value, frame) catch |err| return mapActionError(err);
    try self.finishAction(command.wait_ms, deadline);
}

fn press(self: *LiveSession, command: Command, deadline: std.Io.Timestamp) ProcessError!void {
    const key = command.key orelse return error.BadRequest;
    if (key.len == 0 or key.len > 64) return error.BadRequest;
    const root = self.page.frame() orelse return error.NavigationFailed;
    const element = if (command.selector != null or command.target != null)
        try self.findActionElement(root, command)
    else
        null;
    const frame = if (element) |el| try actionFrame(root, el) else root;
    const node = if (element) |el| el.asNode() else null;
    _ = try remainingCommandMs(deadline);
    lp.actions.press(node, key, frame) catch |err| return mapActionError(err);
    try self.finishAction(command.wait_ms, deadline);
}

fn commandModifiers(command: Command) lp.Frame.user_input.MouseModifiers {
    return .{
        .alt = command.alt_key,
        .control = command.ctrl_key,
        .meta = command.meta_key,
        .shift = command.shift_key,
    };
}

fn mouseEvent(
    self: *LiveSession,
    kind: lp.Frame.user_input.MouseEventKind,
    command: Command,
    deadline: std.Io.Timestamp,
) ProcessError!void {
    const root = self.page.frame() orelse return error.NavigationFailed;
    const element = try self.findActionElement(root, command);
    const frame = try actionFrame(root, element);
    _ = try remainingCommandMs(deadline);
    lp.actions.mouseEventAt(
        element.asNode(),
        kind,
        @floatFromInt(command.x orelse 0),
        @floatFromInt(command.y orelse 0),
        command.button,
        command.buttons,
        command.detail,
        commandModifiers(command),
        frame,
    ) catch |err| return mapActionError(err);
    try self.finishAction(command.wait_ms, deadline);
}

fn wheel(self: *LiveSession, command: Command, deadline: std.Io.Timestamp) ProcessError!void {
    const root = self.page.frame() orelse return error.NavigationFailed;
    const element = try self.findActionElement(root, command);
    const frame = try actionFrame(root, element);
    _ = try remainingCommandMs(deadline);
    lp.actions.wheelAt(
        element.asNode(),
        @floatFromInt(command.x orelse 0),
        @floatFromInt(command.y orelse 0),
        command.delta_x,
        command.delta_y,
        command.buttons,
        commandModifiers(command),
        frame,
    ) catch |err| return mapActionError(err);
    try self.finishAction(command.wait_ms, deadline);
}

fn keyEvent(
    self: *LiveSession,
    down: bool,
    command: Command,
    deadline: std.Io.Timestamp,
) ProcessError!void {
    const key = command.key orelse return error.BadRequest;
    if (key.len == 0 or key.len > 64) return error.BadRequest;
    const code = command.code orelse "";
    if (code.len > 64) return error.BadRequest;
    const root = self.page.frame() orelse return error.NavigationFailed;
    const element = if (command.selector != null or command.target != null)
        try self.findActionElement(root, command)
    else
        null;
    const frame = if (element) |el| try actionFrame(root, el) else root;
    const node = if (element) |el| el.asNode() else null;
    _ = try remainingCommandMs(deadline);
    lp.actions.keyEvent(node, .{
        .down = down,
        .key = key,
        .code = code,
        .location = command.location,
        .repeat = command.repeat,
        .alt = command.alt_key,
        .control = command.ctrl_key,
        .meta = command.meta_key,
        .shift = command.shift_key,
    }, frame) catch |err| return mapActionError(err);
    try self.finishAction(command.wait_ms, deadline);
}

fn scroll(self: *LiveSession, command: Command, deadline: std.Io.Timestamp) ProcessError!void {
    const root = self.page.frame() orelse return error.NavigationFailed;
    const element = if (command.selector != null or command.target != null)
        try self.findActionElement(root, command)
    else
        null;
    const frame = if (element) |el| try actionFrame(root, el) else root;
    const node = if (element) |el| el.asNode() else null;
    _ = try remainingCommandMs(deadline);
    lp.actions.scroll(node, command.x, command.y, frame) catch |err| return mapActionError(err);
    try self.finishAction(command.wait_ms, deadline);
}

fn finishAction(self: *LiveSession, wait_ms: u32, deadline: std.Io.Timestamp) ProcessError!void {
    _ = try remainingCommandMs(deadline);
    const navigated = self.session.processQueuedNavigation() catch {
        return error.InternalError;
    };
    if (!navigated) {
        _ = try remainingCommandMs(deadline);
        _ = self.pump();
        return;
    }
    var runner = self.session.runner(.{});
    runner.waitForFrame(self.page.frame_id, @min(wait_ms, try remainingCommandMs(deadline)), .{ .until = default_navigation_wait }) catch |err|
        return mapWaitError(err);
}

pub fn pump(self: *LiveSession) u31 {
    return self.session.idleSlice();
}

/// Serializes the current document into `out`. Returns null on success, or a
/// warning when the document could not be serialized but the session survives —
/// nothing usable was written and the caller must report `snapshot: false`.
fn writeSnapshot(self: *LiveSession, out: *std.Io.Writer) ProcessError!?[]const u8 {
    const page = self.page.page() orelse return error.NavigationFailed;
    const frame = self.page.frame() orelse return error.NavigationFailed;
    const generation = if (self.targets.boundTo(page))
        self.targets.generation
    else
        self.freshTargetGeneration();
    const version = targetVersion(generation);
    var targets: TargetTable = .{
        .page_incarnation = page.incarnation,
        .dom_version = page.dom_version,
        .generation = generation,
    };
    errdefer targets.deinit(self.app.allocator);
    lp.dump.root(frame.window._document, .{
        .with_base = true,
        .with_frames = true,
        .strip = .{ .js = true, .meta = true },
        .live_form_state = true,
        .with_render_csp = true,
        .direct_render_resources = self.direct_resources,
        .live_targets = .{
            .allocator = self.app.allocator,
            .elements = &targets.elements,
            .version = &version,
            .key_secret = self.target_key_secret,
            .page_incarnation = page.incarnation,
        },
    }, out, frame) catch |err| switch (err) {
        error.OutOfMemory => return error.InternalError,
        // dump.root reports both an over-full target table and a writer that
        // ran out of room as WriteFailed. Neither is recoverable by retrying
        // and neither is the client's fault, so degrade instead of failing.
        error.WriteFailed => return self.degrade(page, frame, &targets),
    };
    out.flush() catch return self.degrade(page, frame, &targets);
    // Only knowable once the traversal that assigns the ids has run, so the
    // generation this document was written with is already spent. Refusing
    // targets until the next snapshot rotates it keeps a stale id from ever
    // resolving against a mapping it was not minted from.
    targets.remapped = self.targets.generation == generation and
        !std.mem.eql(*Element, self.targets.elements.items, targets.elements.items);
    self.snapshot_cursor.mark(self.app.allocator, page, frame.base()) catch
        return error.InternalError;
    self.targets.deinit(self.app.allocator);
    self.targets = targets;
    return null;
}

// Give up on this document without giving up on the session. The partial bytes
// left in `out` are never transmitted: the caller reports snapshot:false.
fn degrade(
    self: *LiveSession,
    page: *lp.Page,
    frame: *lp.Frame,
    targets: *TargetTable,
) ProcessError!?[]const u8 {
    targets.deinit(self.app.allocator);
    // Advance past this document: retrying it on every later command would only
    // fail the same way and starve out the events that still work.
    self.snapshot_cursor.mark(self.app.allocator, page, frame.base()) catch
        return error.InternalError;
    return oversized_document_warning;
}

fn snapshotChanged(self: *LiveSession) ProcessError!bool {
    const page = self.page.page() orelse return error.NavigationFailed;
    const frame = self.page.frame() orelse return error.NavigationFailed;
    // A remapped table refuses every target, so one more snapshot is owed even
    // if the document is otherwise identical: it rotates the generation and
    // gives the client usable targets again.
    if (self.targets.remapped) return true;
    return self.snapshot_cursor.changed(page, frame.base());
}

fn findElement(frame: *lp.Frame, selector: ?[]const u8) ProcessError!*Element {
    const input = selector orelse return error.BadRequest;
    if (input.len == 0 or input.len > 2048) return error.BadRequest;
    const element = Selector.querySelector(frame.window._document.asNode(), input, frame) catch |err|
        return if (err == error.OutOfMemory) error.InternalError else error.BadRequest;
    return element orelse error.NodeNotFound;
}

fn findActionElement(
    self: *LiveSession,
    frame: *lp.Frame,
    command: Command,
) ProcessError!*Element {
    if (command.target) |target| return self.findTarget(frame, target);
    return findElement(frame, command.selector);
}

fn findTarget(self: *LiveSession, frame: *lp.Frame, target: Target) ProcessError!*Element {
    const generation = parseTargetVersion(target.version) orelse return error.StaleTarget;
    if (generation != self.targets.generation) return error.StaleTarget;

    const page = self.page.page() orelse return error.StaleTarget;
    if (self.targets.page_incarnation != page.incarnation or
        self.targets.dom_version != page.dom_version or
        self.targets.remapped or
        self.targets.page_incarnation == 0 or
        self.targets.generation == 0)
    {
        return error.StaleTarget;
    }
    if (target.id == 0 or target.id > @as(u32, lp.dump.MAX_LIVE_TARGETS)) {
        return error.StaleTarget;
    }

    const index: usize = @intCast(target.id - 1);
    if (index >= self.targets.elements.items.len) return error.StaleTarget;
    const element = self.targets.elements.items[index];
    if (!element.asNode().isConnected() or element.ownerFrame(frame)._page != page) {
        return error.StaleTarget;
    }
    return element;
}

fn actionFrame(root: *lp.Frame, element: *Element) ProcessError!*lp.Frame {
    const owner = element.ownerFrame(root);
    if (owner._page != root._page) return error.StaleTarget;
    return owner;
}

fn freshTargetGeneration(self: *LiveSession) u64 {
    const generation = self.next_target_generation;
    self.next_target_generation +%= 1;
    if (self.next_target_generation == 0) self.next_target_generation = 1;
    return generation;
}

fn targetVersion(generation: u64) [16]u8 {
    const big_endian = std.mem.nativeToBig(u64, generation);
    return std.fmt.bytesToHex(std.mem.asBytes(&big_endian), .lower);
}

fn parseTargetVersion(version: []const u8) ?u64 {
    if (version.len != 16) return null;
    for (version) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    }
    const generation = std.fmt.parseUnsigned(u64, version, 16) catch return null;
    return if (generation == 0) null else generation;
}

pub fn parseCommand(arena: std.mem.Allocator, body: []const u8) ProcessError!Command {
    return std.json.parseFromSliceLeaky(Command, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.InternalError,
        else => error.BadRequest,
    };
}

fn validateOpen(arena: std.mem.Allocator, command: Command) ProcessError![:0]const u8 {
    const raw_url = command.url orelse return error.BadRequest;
    if (command.width == 0 or command.width > 8192 or
        command.height == 0 or command.height > 8192)
    {
        return error.BadRequest;
    }
    return canonicalURL(arena, raw_url);
}

fn canonicalURL(arena: std.mem.Allocator, raw: []const u8) ProcessError![:0]const u8 {
    if (raw.len == 0 or raw.len > 8 * 1024) return error.BadRequest;
    const canonical = lp.URL.resolveNavigation(arena, raw, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.InternalError,
        else => error.BadRequest,
    };
    const protocol = lp.URL.getProtocol(canonical);
    if ((!std.mem.eql(u8, protocol, "http:") and !std.mem.eql(u8, protocol, "https:")) or
        lp.URL.getUsername(canonical).len != 0 or lp.URL.getPassword(canonical).len != 0)
    {
        return error.BadRequest;
    }
    return canonical;
}

/// Blocking managed-Turnstile solve for a freshly navigated page, so the
/// snapshot we ship is the post-solve DOM rather than the challenge page.
/// Honours `--solve-captchas` (auto = on under `--stealth`) exactly as `fetch`
/// does. Returns the outcome tag, or null when solving is off.
///
/// `started` is when the navigation began: the solve gets whatever is left of
/// the command's `wait_ms`, never a fresh budget, and is capped by `deadline`.
/// An ordinary page costs only the time to go idle — `Runner.solveTurnstile`
/// returns `.no_widget` the first time the frame settles with nothing to solve.
fn solveTurnstile(
    app: *App,
    session: *lp.Session,
    wait_ms: u32,
    started: std.Io.Timestamp,
    deadline: std.Io.Timestamp,
) ?[]const u8 {
    if (app.config.solveCaptchas() == false) return null;
    const spent: u32 = @intCast(started.untilNow(lp.io, .boot).toMilliseconds());
    // No budget left means we never looked, which is not an outcome. The
    // command's own deadline check reports the timeout.
    const remaining = remainingCommandMs(deadline) catch return null;
    const budget = @min(wait_ms -| spent, remaining);
    if (budget == 0) return null;

    var runner = session.runner(.{});
    // A solve we could not finish is not fatal: the caller still gets the
    // snapshot, and the outcome tells it what it is looking at.
    const result = runner.solveTurnstile(budget) catch |err| {
        lp.log.debug(.app, "live turnstile solve", .{ .err = @errorName(err) });
        return null;
    };
    lp.log.info(.app, "live turnstile", .{ .result = @tagName(result), .budget_ms = budget });
    return @tagName(result);
}

fn commandDeadline(max_wait_ms: u32) std.Io.Timestamp {
    return std.Io.Timestamp.now(lp.io, .boot).addDuration(
        .fromMilliseconds(@intCast(max_wait_ms)),
    );
}

fn remainingCommandMs(deadline: std.Io.Timestamp) ProcessError!u32 {
    const remaining_ns = std.Io.Timestamp.now(lp.io, .boot)
        .durationTo(deadline)
        .toNanoseconds();
    if (remaining_ns <= 0) return error.Timeout;
    const rounded_ms = @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return std.math.cast(u32, rounded_ms) orelse std.math.maxInt(u32);
}

fn mapWaitError(err: anyerror) ProcessError {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.OutOfMemory => error.InternalError,
        else => error.NavigationFailed,
    };
}

fn mapActionError(err: anyerror) ProcessError {
    return switch (err) {
        error.InvalidNodeType => error.BadRequest,
        else => error.InternalError,
    };
}

fn mapNavigationActionError(err: anyerror) ProcessError {
    return switch (err) {
        error.InvalidStateError, error.MissingURL => error.NavigationFailed,
        error.OutOfMemory => error.InternalError,
        else => error.NavigationFailed,
    };
}

test "live session: command parser reads action" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const command = try parseCommand(
        arena.allocator(),
        "{\"id\":7,\"type\":\"fill\",\"selector\":\"#name\",\"value\":\"Ada\",\"snapshot\":false}",
    );
    try std.testing.expectEqual(@as(u32, 7), command.id);
    try std.testing.expectEqual(Action.fill, command.type);
    try std.testing.expect(!command.snapshot);

    const clicked = try parseCommand(
        arena.allocator(),
        "{\"id\":8,\"type\":\"click\",\"selector\":\"#button\",\"x\":37,\"y\":42,\"alt_key\":true,\"shift_key\":true}",
    );
    try std.testing.expectEqual(@as(?i32, 37), clicked.x);
    try std.testing.expectEqual(@as(?i32, 42), clicked.y);
    try std.testing.expect(clicked.alt_key);
    try std.testing.expect(clicked.shift_key);

    const animated = try parseCommand(
        arena.allocator(),
        "{\"id\":9,\"type\":\"animationend\",\"target\":{\"version\":\"0000000000000001\",\"id\":3}}",
    );
    try std.testing.expectEqual(Action.animationend, animated.type);
    try std.testing.expectEqual(@as(u32, 3), animated.target.?.id);

    const opened = try parseCommand(
        arena.allocator(),
        "{\"id\":10,\"type\":\"open\",\"url\":\"https://example.com\",\"direct_resources\":\"on\"}",
    );
    try std.testing.expectEqual(DirectResources.on, opened.direct_resources);
    try std.testing.expect(opened.direct_resources.enabled(testing.test_app.config));

    const blocked = try parseCommand(
        arena.allocator(),
        "{\"id\":10,\"type\":\"open\",\"url\":\"https://example.com\"}",
    );
    try std.testing.expectEqual(DirectResources.off, blocked.direct_resources);
    try std.testing.expect(!blocked.direct_resources.enabled(testing.test_app.config));

    const automatic = try parseCommand(
        arena.allocator(),
        "{\"id\":10,\"type\":\"open\",\"url\":\"https://example.com\",\"direct_resources\":\"auto\"}",
    );
    try std.testing.expectEqual(
        !testing.test_app.config.stealth(),
        automatic.direct_resources.enabled(testing.test_app.config),
    );

    const held = try parseCommand(
        arena.allocator(),
        "{\"id\":11,\"type\":\"keydown\",\"key\":\"a\",\"code\":\"KeyA\",\"location\":3,\"repeat\":true}",
    );
    try std.testing.expectEqual(Action.keydown, held.type);
    try std.testing.expectEqualStrings("KeyA", held.code.?);
    try std.testing.expectEqual(@as(u32, 3), held.location);
    try std.testing.expect(held.repeat);

    const wheeled = try parseCommand(
        arena.allocator(),
        "{\"id\":12,\"type\":\"wheel\",\"delta_x\":-3.5,\"delta_y\":7,\"buttons\":4,\"button\":2,\"detail\":2}",
    );
    try std.testing.expectEqual(Action.wheel, wheeled.type);
    try std.testing.expectEqual(@as(f64, -3.5), wheeled.delta_x);
    try std.testing.expectEqual(@as(f64, 7), wheeled.delta_y);
    try std.testing.expectEqual(@as(u16, 4), wheeled.buttons);
    try std.testing.expectEqual(@as(i32, 2), wheeled.button);
    try std.testing.expectEqual(@as(u32, 2), wheeled.detail);

    try std.testing.expectEqual(Action.mouseover, (try parseCommand(
        arena.allocator(),
        "{\"id\":13,\"type\":\"mouseover\"}",
    )).type);
}

test "live session: keyboard and pointer commands dispatch real events" {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var state: ?LiveSession = null;
    defer if (state) |*live| live.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const owner: u64 = 41;
    const opened = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":1,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session.html\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(opened.snapshot);
    out.clearRetainingCapacity();

    // A held key: keydown carries repeat/code/location, keyup is its own event.
    _ = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":2,\"type\":\"keydown\",\"key\":\"a\",\"code\":\"KeyA\",\"location\":1,\"repeat\":true,\"shift_key\":true,\"snapshot\":false}",
        2_000,
        &out.writer,
    );
    _ = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":3,\"type\":\"keyup\",\"key\":\"a\",\"code\":\"KeyA\",\"snapshot\":false}",
        2_000,
        &out.writer,
    );

    inline for ([_][]const u8{
        "{{\"id\":5,\"type\":\"mouseover\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"x\":11,\"y\":13,\"detail\":0,\"snapshot\":false}}",
        "{{\"id\":7,\"type\":\"mousemove\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"x\":11,\"y\":13,\"detail\":0,\"snapshot\":false}}",
        "{{\"id\":9,\"type\":\"contextmenu\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"x\":11,\"y\":13,\"button\":2,\"detail\":0,\"snapshot\":false}}",
        "{{\"id\":11,\"type\":\"dblclick\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"x\":11,\"y\":13,\"detail\":2,\"snapshot\":false}}",
        "{{\"id\":13,\"type\":\"wheel\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"x\":11,\"y\":13,\"delta_x\":3,\"delta_y\":7,\"snapshot\":false}}",
    }, 0..) |template, index| {
        out.clearRetainingCapacity();
        const refresh_command = try std.fmt.allocPrint(
            arena,
            "{{\"id\":{d},\"type\":\"snapshot\"}}",
            .{4 + index * 2},
        );
        const refreshed = try process(
            &state,
            testing.test_app,
            &browser,
            arena,
            owner,
            refresh_command,
            2_000,
            &out.writer,
        );
        try std.testing.expect(refreshed.snapshot);
        const version = refreshed.target_version.?;
        const pointer_id = tableTargetId(&state.?, "pointer-target").?;
        out.clearRetainingCapacity();
        const command = try std.fmt.allocPrint(arena, template, .{ &version, pointer_id });
        _ = try process(&state, testing.test_app, &browser, arena, owner, command, 2_000, &out.writer);
    }

    const refreshed = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":14,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(refreshed.snapshot);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "keydown:a:KeyA:1:true:false:false:false:true|keyup:a:KeyA:0:false:false:false:false:false",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "mouseover:pointer-target:11:13:0:0:0:0:false:false:false:false" ++
            "|mousemove:pointer-target:11:13:0:0:0:0:false:false:false:false" ++
            "|contextmenu:pointer-target:11:13:0:0:0:0:false:false:false:false" ++
            "|dblclick:pointer-target:11:13:0:2:0:0:false:false:false:false" ++
            "|wheel:pointer-target:11:13:0:0:3:7:false:false:false:false",
    ) != null);
}

test "live session: target versions are exact lowercase nonzero hex" {
    const one = targetVersion(1);
    try std.testing.expectEqualStrings("0000000000000001", &one);
    try std.testing.expectEqual(@as(?u64, 1), parseTargetVersion(&one));
    try std.testing.expectEqual(@as(?u64, null), parseTargetVersion("0000000000000000"));
    try std.testing.expectEqual(@as(?u64, null), parseTargetVersion("000000000000000A"));
    try std.testing.expectEqual(@as(?u64, null), parseTargetVersion("000000000000001"));
    try std.testing.expectEqual(@as(?u64, null), parseTargetVersion("000000000000000g"));
}

test "live session: the target generation survives a mutation that keeps the mapping" {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var state: ?LiveSession = null;
    defer if (state) |*live| live.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const owner: u64 = 71;
    const opened = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":1,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session_targets.html\"}",
        2_000,
        &out.writer,
    );
    const first_version = opened.target_version.?;
    out.clearRetainingCapacity();

    // Text-only mutation: same elements, same ids, so the whole document except
    // the changed text must stay byte-identical for the delta encoder.
    const restyled = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":2,\"type\":\"click\",\"selector\":\"#restyle\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(restyled.snapshot);
    try std.testing.expectEqualSlices(u8, &first_version, &restyled.target_version.?);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ">1</p>") != null);
    out.clearRetainingCapacity();

    // Structural mutation: the mapping moved, so targets are refused until the
    // next snapshot, which `snapshotChanged` owes the client, rotates.
    const grown = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":3,\"type\":\"click\",\"selector\":\"#grow\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(grown.snapshot);
    try std.testing.expect(state.?.targets.remapped);
    try std.testing.expect(try state.?.snapshotChanged());
    out.clearRetainingCapacity();

    const stale = try std.fmt.allocPrint(
        arena,
        "{{\"id\":4,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":1}},\"snapshot\":false}}",
        .{&grown.target_version.?},
    );
    try std.testing.expectError(error.StaleTarget, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        stale,
        2_000,
        &out.writer,
    ));
    out.clearRetainingCapacity();

    const resynced = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":5,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(resynced.snapshot);
    try std.testing.expect(!state.?.targets.remapped);
    try std.testing.expect(!std.mem.eql(u8, &first_version, &resynced.target_version.?));
}

test "live session: snapshot cursor detects page and state changes" {
    const first = try std.testing.allocator.create(lp.Page);
    defer std.testing.allocator.destroy(first);
    const second = try std.testing.allocator.create(lp.Page);
    defer std.testing.allocator.destroy(second);
    first.* = undefined;
    second.* = undefined;
    first.incarnation = 1;
    second.incarnation = 2;
    first.snapshot_version = 1;
    second.snapshot_version = 1;

    var cursor: SnapshotCursor = .{};
    defer cursor.deinit(std.testing.allocator);
    try std.testing.expect(cursor.changed(first, "https://example.test/a"));
    try cursor.mark(std.testing.allocator, first, "https://example.test/a");
    try std.testing.expect(!cursor.changed(first, "https://example.test/a"));
    try std.testing.expect(cursor.changed(first, "https://example.test/b"));
    try cursor.mark(std.testing.allocator, first, "https://example.test/b");
    first.snapshot_version += 1;
    try std.testing.expect(cursor.changed(first, "https://example.test/b"));
    try cursor.mark(std.testing.allocator, first, "https://example.test/b");
    try std.testing.expect(cursor.changed(second, "https://example.test/b"));
}

const testing = @import("../testing.zig");

fn tableTargetId(live: *const LiveSession, element_id: []const u8) ?u32 {
    for (live.targets.elements.items, 1..) |element, id| {
        const value = element.getAttributeSafe(comptime .wrap("id")) orelse continue;
        if (std.mem.eql(u8, value, element_id)) return @intCast(id);
    }
    return null;
}

/// A changed id->element mapping is only visible once the document that carries
/// it has been serialized, so the generation rotates on the snapshot after it.
/// `snapshotChanged` forces that one, which in the real client is what its
/// stale-target retry fetches. Leaves the second document in `out`.
fn snapshotAfterRemap(
    state: *?LiveSession,
    browser: *lp.Browser,
    arena: std.mem.Allocator,
    owner: u64,
    out: *std.Io.Writer.Allocating,
) !Outcome {
    _ = try process(
        state,
        testing.test_app,
        browser,
        arena,
        owner,
        "{\"id\":1000,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    out.clearRetainingCapacity();
    return process(
        state,
        testing.test_app,
        browser,
        arena,
        owner,
        "{\"id\":1001,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
}

fn snapshotTargetId(
    html: []const u8,
    element_id: []const u8,
    version: []const u8,
) ?u32 {
    var id_buffer: [128]u8 = undefined;
    const id_attribute = std.fmt.bufPrint(
        &id_buffer,
        "id=\"{s}\"",
        .{element_id},
    ) catch return null;
    const id_pos = std.mem.indexOf(u8, html, id_attribute) orelse return null;
    const tag_end = std.mem.indexOfScalarPos(u8, html, id_pos, '>') orelse return null;

    var marker_buffer: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(
        &marker_buffer,
        "data-lp-t-{s}=\"",
        .{version},
    ) catch return null;
    const marker_pos = std.mem.indexOfPos(u8, html, id_pos, marker) orelse return null;
    if (marker_pos >= tag_end) return null;
    const value_start = marker_pos + marker.len;
    const value_end = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse return null;
    if (value_end > tag_end) return null;
    return std.fmt.parseUnsigned(u32, html[value_start..value_end], 10) catch null;
}

fn snapshotTargetKey(
    html: []const u8,
    element_id: []const u8,
    version: []const u8,
) ?[16]u8 {
    var id_buffer: [128]u8 = undefined;
    const id_attribute = std.fmt.bufPrint(
        &id_buffer,
        "id=\"{s}\"",
        .{element_id},
    ) catch return null;
    const id_pos = std.mem.indexOf(u8, html, id_attribute) orelse return null;
    const tag_end = std.mem.indexOfScalarPos(u8, html, id_pos, '>') orelse return null;

    var marker_buffer: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(
        &marker_buffer,
        "data-lp-k-{s}=\"",
        .{version},
    ) catch return null;
    const marker_pos = std.mem.indexOfPos(u8, html, id_pos, marker) orelse return null;
    if (marker_pos >= tag_end) return null;
    const value_start = marker_pos + marker.len;
    const value_end = value_start + 16;
    if (value_end >= tag_end or html[value_end] != '"') return null;
    for (html[value_start..value_end]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    }
    var key: [16]u8 = undefined;
    @memcpy(&key, html[value_start..value_end]);
    return key;
}

test "live session: child frame targets dispatch click and animation end" {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var state: ?LiveSession = null;
    defer if (state) |*live| live.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const owner: u64 = 32;
    const opened = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":1,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session_frame.html\",\"wait_until\":\"done\"}",
        2_000,
        &out.writer,
    );
    const version = opened.target_version.?;
    const html = out.written();

    try std.testing.expect(state.?.session.subframe_loading_enabled);
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, html, "data-lightpanda-live-frame"),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "data-lightpanda-live-frame=\"spoof\"",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "&lt;base href=&quot;http://127.0.0.1:9582/src/browser/tests/render/live_session_frame_child.html&quot;&gt;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "&amp;lt;base href=&amp;quot;http://127.0.0.1:9582/src/browser/tests/render/live_session_frame_grandchild.html&amp;quot;&amp;gt;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&amp;lt;script") == null);

    const child_id = tableTargetId(&state.?, "child-button").?;
    const root = state.?.page.frame().?;
    const child_index: usize = @intCast(child_id - 1);
    const child_element = state.?.targets.elements.items[child_index];
    try std.testing.expect(child_element.ownerFrame(root) != root);
    try std.testing.expect(child_element.ownerFrame(root)._page == root._page);

    var marker_buffer: [64]u8 = undefined;
    const escaped_marker = try std.fmt.bufPrint(
        &marker_buffer,
        "data-lp-t-{s}=&quot;{d}&quot;",
        .{ &version, child_id },
    );
    try std.testing.expect(std.mem.indexOf(u8, html, escaped_marker) != null);
    out.clearRetainingCapacity();

    const click_command = try std.fmt.allocPrint(
        arena,
        "{{\"id\":2,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}}}}",
        .{ &version, child_id },
    );
    const clicked = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        click_command,
        2_000,
        &out.writer,
    );
    try std.testing.expect(clicked.snapshot);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "&gt;clicked&lt;/output&gt;",
    ) != null);

    const animation_version = clicked.target_version.?;
    const animation_id = tableTargetId(&state.?, "child-animation-target").?;
    out.clearRetainingCapacity();
    const animation_command = try std.fmt.allocPrint(
        arena,
        "{{\"id\":3,\"type\":\"animationend\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}}}}",
        .{ &animation_version, animation_id },
    );
    const animated = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        animation_command,
        2_000,
        &out.writer,
    );
    try std.testing.expect(animated.snapshot);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "animationend:true:true:false:1",
    ) != null);
}

test "live session: opaque targets cover rendered shadow and slot elements" {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var state: ?LiveSession = null;
    defer if (state) |*live| live.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const owner: u64 = 31;
    const opened = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":1,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session.html\"}",
        2_000,
        &out.writer,
    );
    const first_version = opened.target_version.?;
    try std.testing.expect(opened.snapshot);
    try std.testing.expect(state.?.targets.elements.items.len > 0);
    try std.testing.expect(state.?.targets.elements.capacity < lp.dump.MAX_LIVE_TARGETS);
    var marker_buffer: [32]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buffer, "data-lp-t-{s}=", .{&first_version});
    try std.testing.expectEqual(
        state.?.targets.elements.items.len,
        std.mem.count(u8, out.written(), marker),
    );
    var key_marker_buffer: [32]u8 = undefined;
    const key_marker = try std.fmt.bufPrint(
        &key_marker_buffer,
        "data-lp-k-{s}=",
        .{&first_version},
    );
    try std.testing.expectEqual(
        state.?.targets.elements.items.len,
        std.mem.count(u8, out.written(), key_marker),
    );
    var first_marker_buffer: [48]u8 = undefined;
    const first_marker = try std.fmt.bufPrint(
        &first_marker_buffer,
        "data-lp-t-{s}=\"1\"",
        .{&first_version},
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), first_marker) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "data-lp-t-0123456789abcdef=\"65535\"",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "data-lp-k-0123456789abcdef=\"deadbeefdeadbeef\"",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "data-lightpanda-live-indeterminate",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "data-lightpanda-live-selected-none",
    ) != null);

    const shadow_id = tableTargetId(&state.?, "shadow-button").?;
    const slot_id = tableTargetId(&state.?, "slot-input").?;
    try std.testing.expectEqual(
        shadow_id,
        snapshotTargetId(out.written(), "shadow-button", &first_version).?,
    );
    try std.testing.expectEqual(
        slot_id,
        snapshotTargetId(out.written(), "slot-input", &first_version).?,
    );

    var slot_count: usize = 0;
    for (state.?.targets.elements.items) |element| {
        const id = element.getAttributeSafe(comptime .wrap("id")) orelse continue;
        if (std.mem.eql(u8, id, "slot-input")) slot_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), slot_count);
    out.clearRetainingCapacity();

    const fill_command = try std.fmt.allocPrint(
        arena,
        "{{\"id\":2,\"type\":\"fill\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"value\":\"slot-new\",\"snapshot\":false}}",
        .{ &first_version, slot_id },
    );
    const filled = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        fill_command,
        2_000,
        &out.writer,
    );
    try std.testing.expect(!filled.snapshot);

    const after_fill = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":3,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(after_fill.snapshot);
    try std.testing.expectEqualSlices(u8, &first_version, &after_fill.target_version.?);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "value=\"slot-new\"") != null);
    out.clearRetainingCapacity();

    const bad_range = try std.fmt.allocPrint(
        arena,
        "{{\"id\":4,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":65535}},\"snapshot\":false}}",
        .{&first_version},
    );
    try std.testing.expectError(error.StaleTarget, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        bad_range,
        2_000,
        &out.writer,
    ));
    try std.testing.expectError(error.StaleTarget, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":5,\"type\":\"click\",\"target\":{\"version\":\"0000000000000000\",\"id\":1},\"snapshot\":false}",
        2_000,
        &out.writer,
    ));

    const mixed_command = try std.fmt.allocPrint(
        arena,
        "{{\"id\":6,\"type\":\"click\",\"selector\":\"#shadow-host\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"snapshot\":false}}",
        .{ &first_version, shadow_id },
    );
    try std.testing.expectError(error.BadRequest, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        mixed_command,
        2_000,
        &out.writer,
    ));

    const current_shadow_id = tableTargetId(&state.?, "shadow-button").?;
    const click_command = try std.fmt.allocPrint(
        arena,
        "{{\"id\":7,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}}}}",
        .{ &first_version, current_shadow_id },
    );
    const clicked = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        click_command,
        2_000,
        &out.writer,
    );
    try std.testing.expect(clicked.snapshot);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ">clicked</output>") != null);
    // Text changed, the element list did not, so the generation holds and the
    // whole document outside that text stays byte-identical for the delta.
    try std.testing.expectEqualSlices(
        u8,
        &first_version,
        &clicked.target_version.?,
    );
    const reorder_version = clicked.target_version.?;
    const original_reorder_key = snapshotTargetKey(
        out.written(),
        "reorder-first",
        &reorder_version,
    ).?;
    const event_child_id = tableTargetId(&state.?, "event-child").?;
    out.clearRetainingCapacity();
    {
        const frame = state.?.page.frame().?;
        try frame.window.scrollTo(.{ .x = 5 }, 7, frame);
    }
    const coordinate_click = try std.fmt.allocPrint(
        arena,
        "{{\"id\":70,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"x\":37,\"y\":42,\"alt_key\":true,\"ctrl_key\":true,\"meta_key\":true,\"shift_key\":true}}",
        .{ &reorder_version, event_child_id },
    );
    const coordinate_clicked = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        coordinate_click,
        2_000,
        &out.writer,
    );
    try std.testing.expect(coordinate_clicked.snapshot);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "mousedown:event-child:37:42:42:49:1:1:true:true:true:true|mouseup:event-child:37:42:42:49:0:1:true:true:true:true|click:event-child:37:42:42:49:0:1:true:true:true:true",
    ) != null);
    const coordinate_version = coordinate_clicked.target_version.?;
    const reorder_id = tableTargetId(&state.?, "reorder-first").?;
    out.clearRetainingCapacity();
    {
        const frame = state.?.page.frame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.exec(
            "const first = document.querySelector('#reorder-first'); first.parentNode.appendChild(first)",
            null,
        );
    }
    const moved_command = try std.fmt.allocPrint(
        arena,
        "{{\"id\":8,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"snapshot\":false}}",
        .{ &coordinate_version, reorder_id },
    );
    try std.testing.expectError(error.StaleTarget, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        moved_command,
        2_000,
        &out.writer,
    ));

    const refreshed = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":9,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    const refreshed_version = refreshed.target_version.?;
    const reordered_key = snapshotTargetKey(
        out.written(),
        "reorder-first",
        &refreshed_version,
    ).?;
    try std.testing.expectEqualSlices(u8, &original_reorder_key, &reordered_key);
    out.clearRetainingCapacity();

    {
        const frame = state.?.page.frame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.exec(
            "(() => { const old = document.querySelector('#reorder-first'); old.parentNode.replaceChild(old.cloneNode(true), old) })()",
            null,
        );
    }
    const replaced = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":10,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    const navigation_version = replaced.target_version.?;
    const replacement_key = snapshotTargetKey(
        out.written(),
        "reorder-first",
        &navigation_version,
    ).?;
    try std.testing.expect(!std.mem.eql(u8, &reordered_key, &replacement_key));
    const navigation_target = tableTargetId(&state.?, "reorder-second").?;
    const navigation_key = snapshotTargetKey(
        out.written(),
        "reorder-second",
        &navigation_version,
    ).?;
    const navigation_page = state.?.page.page().?;
    const navigation_page_address = @intFromPtr(navigation_page);
    const navigation_loader = state.?.page.frame().?._loader_id;
    const navigation_incarnation = navigation_page.incarnation;
    out.clearRetainingCapacity();

    // Force the u32 loader counter through 0 and back to the original value.
    // The Page pool then reuses the original Page address as well.
    state.?.session.loader_id_gen = std.math.maxInt(u32);
    try state.?.session.initiateRootNavigation(
        state.?.page.frame_id,
        "http://127.0.0.1:9582/src/browser/tests/render/live_session.html",
        .{
            .reason = .address_bar,
            .kind = .{ .push = null },
        },
    );
    var runner = state.?.session.runner(.{});
    try runner.waitForFrame(state.?.page.frame_id, 2_000, .{ .until = .done });
    try std.testing.expectEqual(@as(u32, 0), state.?.page.frame().?._loader_id);
    state.?.session.processDestroyQueues();

    try state.?.session.initiateRootNavigation(
        state.?.page.frame_id,
        "http://127.0.0.1:9582/src/browser/tests/render/live_session.html",
        .{
            .reason = .address_bar,
            .kind = .{ .push = null },
        },
    );
    try runner.waitForFrame(state.?.page.frame_id, 2_000, .{ .until = .done });
    const wrapped_page = state.?.page.page().?;
    try std.testing.expectEqual(navigation_loader, state.?.page.frame().?._loader_id);
    try std.testing.expectEqual(navigation_page_address, @intFromPtr(wrapped_page));
    try std.testing.expect(navigation_incarnation != wrapped_page.incarnation);
    try std.testing.expect(try state.?.snapshotChanged());

    const navigation_stale = try std.fmt.allocPrint(
        arena,
        "{{\"id\":11,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"snapshot\":false}}",
        .{ &navigation_version, navigation_target },
    );
    try std.testing.expectError(error.StaleTarget, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        navigation_stale,
        2_000,
        &out.writer,
    ));

    const after_wrap = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":12,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    const after_wrap_key = snapshotTargetKey(
        out.written(),
        "reorder-second",
        &after_wrap.target_version.?,
    ).?;
    try std.testing.expect(!std.mem.eql(u8, &navigation_key, &after_wrap_key));
}

test "live session: composed tree changes invalidate opaque targets" {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var state: ?LiveSession = null;
    defer if (state) |*live| live.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const owner: u64 = 37;
    const opened = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":1,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session.html\"}",
        2_000,
        &out.writer,
    );
    const first_version = opened.target_version.?;
    const light_id = tableTargetId(&state.?, "late-shadow-light").?;
    out.clearRetainingCapacity();

    {
        const frame = state.?.page.frame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.exec(
            "document.querySelector('#late-shadow-host').attachShadow({ mode: 'open' })",
            null,
        );
    }
    const stale_light = try std.fmt.allocPrint(
        arena,
        "{{\"id\":2,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"snapshot\":false}}",
        .{ &first_version, light_id },
    );
    try std.testing.expectError(error.StaleTarget, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        stale_light,
        2_000,
        &out.writer,
    ));

    const after_shadow = try snapshotAfterRemap(&state, &browser, arena, owner, &out);
    try std.testing.expect(after_shadow.snapshot);
    const shadow_version = after_shadow.target_version.?;
    try std.testing.expect(!std.mem.eql(u8, &first_version, &shadow_version));
    try std.testing.expect(snapshotTargetId(
        out.written(),
        "late-shadow-light",
        &shadow_version,
    ) == null);
    const manual_id = tableTargetId(&state.?, "manual-first").?;
    out.clearRetainingCapacity();

    {
        const frame = state.?.page.frame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.exec(
            "window.manualSlot.assign(document.querySelector('#manual-second'))",
            null,
        );
    }
    const stale_manual = try std.fmt.allocPrint(
        arena,
        "{{\"id\":4,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"snapshot\":false}}",
        .{ &shadow_version, manual_id },
    );
    try std.testing.expectError(error.StaleTarget, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        stale_manual,
        2_000,
        &out.writer,
    ));

    const after_assign = try snapshotAfterRemap(&state, &browser, arena, owner, &out);
    try std.testing.expect(after_assign.snapshot);
    const assign_version = after_assign.target_version.?;
    try std.testing.expect(!std.mem.eql(u8, &shadow_version, &assign_version));
    try std.testing.expect(snapshotTargetId(
        out.written(),
        "manual-first",
        &assign_version,
    ) == null);
    try std.testing.expect(snapshotTargetId(
        out.written(),
        "manual-second",
        &assign_version,
    ) != null);
    const manual_second_id = tableTargetId(&state.?, "manual-second").?;
    out.clearRetainingCapacity();

    {
        const frame = state.?.page.frame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.exec(
            "window.detachedManualSlot.assign(document.querySelector('#manual-second'))",
            null,
        );
    }
    const detached_stale = try std.fmt.allocPrint(
        arena,
        "{{\"id\":6,\"type\":\"click\",\"target\":{{\"version\":\"{s}\",\"id\":{d}}},\"snapshot\":false}}",
        .{ &assign_version, manual_second_id },
    );
    try std.testing.expectError(error.StaleTarget, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        detached_stale,
        2_000,
        &out.writer,
    ));

    const after_detached_assign = try snapshotAfterRemap(&state, &browser, arena, owner, &out);
    try std.testing.expect(after_detached_assign.snapshot);
    const detached_version = after_detached_assign.target_version.?;
    try std.testing.expect(!std.mem.eql(u8, &assign_version, &detached_version));
    try std.testing.expect(snapshotTargetId(
        out.written(),
        "manual-second",
        &detached_version,
    ) == null);
}

test "live session: failed navigation preserves committed opaque targets" {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var state: ?LiveSession = null;
    defer if (state) |*live| live.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const owner: u64 = 39;
    const opened = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":1,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session.html\"}",
        2_000,
        &out.writer,
    );
    const version = opened.target_version.?;
    const target_id = tableTargetId(&state.?, "reorder-second").?;
    out.clearRetainingCapacity();

    try std.testing.expectError(error.NavigationFailed, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":2,\"type\":\"navigate\",\"url\":\"http://127.0.0.1:9584/\",\"snapshot\":false}",
        2_000,
        &out.writer,
    ));

    const frame = state.?.page.frame().?;
    const target = try state.?.findTarget(frame, .{
        .version = &version,
        .id = target_id,
    });
    try std.testing.expectEqualStrings(
        "reorder-second",
        target.getAttributeSafe(comptime .wrap("id")).?,
    );
}

test "live session: history controls report committed navigation state" {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var state: ?LiveSession = null;
    defer if (state) |*live| live.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const owner: u64 = 36;
    const opened = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":1,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session.html\",\"wait_until\":\"done\"}",
        3_000,
        &out.writer,
    );
    try std.testing.expect(!opened.can_go_back);
    try std.testing.expect(!opened.can_go_forward);

    out.clearRetainingCapacity();
    const clicked = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":2,\"type\":\"click\",\"selector\":\"#slow\"}",
        3_000,
        &out.writer,
    );
    try std.testing.expect(clicked.snapshot);
    try std.testing.expect(clicked.can_go_back);
    try std.testing.expect(!clicked.can_go_forward);
    try std.testing.expect(std.mem.endsWith(
        u8,
        state.?.page.frame().?.url,
        "/src/browser/tests/render/live_session.html?delay_ms=100",
    ));

    out.clearRetainingCapacity();
    const backed = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":3,\"type\":\"back\"}",
        3_000,
        &out.writer,
    );
    try std.testing.expect(backed.snapshot);
    try std.testing.expect(!backed.can_go_back);
    try std.testing.expect(backed.can_go_forward);
    try std.testing.expect(std.mem.endsWith(
        u8,
        state.?.page.frame().?.url,
        "/src/browser/tests/render/live_session.html",
    ));

    out.clearRetainingCapacity();
    const forwarded = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":4,\"type\":\"forward\"}",
        3_000,
        &out.writer,
    );
    try std.testing.expect(forwarded.snapshot);
    try std.testing.expect(forwarded.can_go_back);
    try std.testing.expect(!forwarded.can_go_forward);

    out.clearRetainingCapacity();
    const reloaded = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":5,\"type\":\"reload\"}",
        3_000,
        &out.writer,
    );
    try std.testing.expect(reloaded.snapshot);
    try std.testing.expect(reloaded.can_go_back);
    try std.testing.expect(!reloaded.can_go_forward);
}

test "live session: snapshot gate tracks live page state" {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var state: ?LiveSession = null;
    defer if (state) |*live| live.deinit();

    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const owner: u64 = 41;
    const opened = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":1,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session.html\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(opened.snapshot);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "id=\"mutation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ">before</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "default-secret") == null);
    const active_session = state.?.session;
    out.clearRetainingCapacity();

    try std.testing.expectError(error.NotOwner, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner + 1,
        "{\"id\":2,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session.html\"}",
        2_000,
        &out.writer,
    ));
    try std.testing.expect(state.?.session == active_session);

    try std.testing.expectError(error.BadRequest, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":3,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session.html\",\"width\":0}",
        2_000,
        &out.writer,
    ));
    try std.testing.expect(state.?.session == active_session);

    const unchanged = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":4,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(!unchanged.snapshot);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    const filled = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":5,\"type\":\"fill\",\"selector\":\"#text\",\"value\":\"changed\",\"snapshot\":false}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(!filled.snapshot);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    const after_fill = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":6,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(after_fill.snapshot);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "value=\"changed\"") != null);
    out.clearRetainingCapacity();

    {
        const frame = state.?.page.frame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.exec(
            "document.querySelector('#mutation').textContent = 'after'",
            null,
        );
    }
    const after_mutation = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":7,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(after_mutation.snapshot);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "id=\"mutation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ">after</p>") != null);
    out.clearRetainingCapacity();

    const password_fill = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":8,\"type\":\"fill\",\"selector\":\"#password\",\"value\":\"runtime-secret\",\"snapshot\":false}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(!password_fill.snapshot);
    const after_password = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":9,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(!after_password.snapshot);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    {
        const frame = state.?.page.frame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.exec(
            "document.querySelector('#mutation').textContent = 'after password'",
            null,
        );
    }
    const redacted = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":10,\"type\":\"snapshot\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(redacted.snapshot);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "runtime-secret") == null);
    out.clearRetainingCapacity();

    try std.testing.expectError(error.Timeout, process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":11,\"type\":\"click\",\"selector\":\"#slow\",\"wait_ms\":1,\"snapshot\":false}",
        2_000,
        &out.writer,
    ));

    const closed = try process(
        &state,
        testing.test_app,
        &browser,
        arena,
        owner,
        "{\"id\":12,\"type\":\"close\"}",
        2_000,
        &out.writer,
    );
    try std.testing.expect(closed.closed);
    try std.testing.expect(state == null);
    try std.testing.expect(browser.session == null);
}

test "live session: oversized poll degrades to a warning and keeps the session" {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var state: ?LiveSession = null;
    defer if (state) |*live| live.deinit();
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();

    var opened: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer opened.deinit();
    _ = try process(
        &state,
        testing.test_app,
        &browser,
        arena_instance.allocator(),
        51,
        "{\"id\":1,\"type\":\"open\",\"url\":\"http://127.0.0.1:9582/src/browser/tests/render/live_session.html\"}",
        2_000,
        &opened.writer,
    );
    {
        const frame = state.?.page.frame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.exec(
            "document.querySelector('#mutation').textContent = 'oversized'",
            null,
        );
    }

    // A document that will not fit is the page's problem, not the client's:
    // answer with snapshot:false plus a warning and keep serving commands.
    var storage: [8]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    const degraded = try process(
        &state,
        testing.test_app,
        &browser,
        arena_instance.allocator(),
        51,
        "{\"id\":2,\"type\":\"snapshot\"}",
        2_000,
        &out,
    );
    try std.testing.expect(!degraded.snapshot);
    try std.testing.expectEqualStrings(oversized_document_warning, degraded.warning.?);
    try std.testing.expectEqual(@as(?[16]u8, null), degraded.target_version);
    try std.testing.expect(state != null);
    try std.testing.expect(browser.session != null);

    // The cursor advanced, so the same doomed document is not retried.
    opened.clearRetainingCapacity();
    const repolled = try process(
        &state,
        testing.test_app,
        &browser,
        arena_instance.allocator(),
        51,
        "{\"id\":3,\"type\":\"snapshot\"}",
        2_000,
        &opened.writer,
    );
    try std.testing.expect(!repolled.snapshot);
    try std.testing.expectEqual(@as(?[]const u8, null), repolled.warning);

    // The session is still the caller's, and still closes on request.
    opened.clearRetainingCapacity();
    const closed_after = try process(
        &state,
        testing.test_app,
        &browser,
        arena_instance.allocator(),
        51,
        "{\"id\":4,\"type\":\"close\"}",
        2_000,
        &opened.writer,
    );
    try std.testing.expect(closed_after.closed);
    try std.testing.expect(state == null);
}
