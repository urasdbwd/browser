// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Interactive Cloudflare Turnstile helper: walk frames, click checkbox-style
// controls in challenge iframes, and drive managed-mode completion.
// Does not outsource visual puzzles to third-party CAPTCHA farms.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("Frame.zig");
const Session = @import("Session.zig");
const Node = @import("webapi/Node.zig");
const actions = @import("actions.zig");
const user_input = @import("frame/user_input.zig");
const Selector = @import("webapi/selector/Selector.zig");
const js = @import("js/js.zig");

const log = lp.log;

/// One interaction pass. `aggressive` adds host-side clicks; keep false for
/// the first few seconds so always-pass widgets can resolve without looking
/// like a bot hammering the checkbox.
pub fn interact(session: *Session, aggressive: bool) void {
    for (session.pages.items) |page| {
        if (page.replacement != null) continue;
        walkFrame(&page.frame, aggressive);
        for (page.popups.items) |popup| {
            walkFrame(popup, aggressive);
        }
    }
}

fn walkFrame(frame: *Frame, aggressive: bool) void {
    if (isChallengeFrame(frame)) {
        clickChallengeFrame(frame);
    } else if (aggressive) {
        clickHostWidget(frame);
    }
    for (frame.child_frames.items) |child| {
        walkFrame(child, aggressive);
    }
}

fn isChallengeFrame(frame: *Frame) bool {
    const url = frame.url;
    if (std.mem.indexOf(u8, url, "challenges.cloudflare.com") != null) return true;
    if (std.mem.indexOf(u8, url, "cdn-cgi/challenge-platform") != null) return true;
    return false;
}

fn clickChallengeFrame(frame: *Frame) void {
    // Prefer explicit interactive targets — avoid blasting every button/body.
    const preferred = [_][]const u8{
        "input[type=checkbox]",
        "[role=checkbox]",
        "label",
        "#success",
    };
    var clicked = false;
    for (preferred) |sel| {
        if (queryOne(frame, sel)) |el| {
            clickElement(frame, el);
            clicked = true;
            break;
        }
    }

    // Fallback: left side of a 300×65 managed widget (checkbox column).
    if (!clicked) {
        const x: f64 = 28;
        const y: f64 = 32;
        user_input.triggerMouseMove(frame, x, y) catch {};
        user_input.triggerMousePress(frame, x, y, user_input.mouse_button.main) catch {};
        user_input.triggerMouseRelease(frame, x, y, user_input.mouse_button.main, 1) catch {};
    }
}

fn clickHostWidget(frame: *Frame) void {
    // Only the iframe itself — not the whole page.
    if (queryOne(frame, "iframe[src*='challenges.cloudflare.com']") orelse
        queryOne(frame, "iframe[src*='turnstile']") orelse
        queryOne(frame, ".cf-turnstile")) |el|
    {
        clickElement(frame, el);
    }
}

fn clickElement(frame: *Frame, el: *Node.Element) void {
    actions.click(el.asNode(), frame) catch |err| {
        log.debug(.browser, "turnstile click", .{ .err = err });
    };
}

fn queryOne(frame: *Frame, sel: []const u8) ?*Node.Element {
    if (Selector.querySelector(frame.document.asNode(), sel, frame) catch null) |el| {
        return el;
    }

    // Challenge controls can live in closed shadow trees. They are hidden
    // from page JavaScript but remain valid automation targets inside the
    // browser, just like closed roots exposed through browser debugging APIs.
    var roots = frame._element_shadow_roots.valueIterator();
    while (roots.next()) |root| {
        if (Selector.querySelector(root.*.asNode(), sel, frame) catch null) |el| {
            return el;
        }
    }
    return null;
}

/// Outcome of a solve attempt.
// ponytail: no `.failed` variant — nothing downstream can tell a widget that
// errored from one that is merely slow, so both land in `.timeout`. Split it
// if we ever read Turnstile's own error callback.
pub const Result = union(enum) {
    /// No Turnstile widget anywhere in the session.
    no_widget,
    /// Token acquired. Lives in the frame arena.
    solved: []const u8,
    /// Widget present but no token before the deadline.
    timeout,
};

/// Wait-script body: true once a Turnstile token is present. Read-only — it
/// must not leave anything the page can observe.
pub const token_wait_script =
    \\(() => {
    \\  try {
    \\    var i = document.querySelector('[name=cf-turnstile-response]');
    \\    return !!(i && i.value && i.value.length > 10);
    \\  } catch (e) {}
    \\  return false;
    \\})()
;

const token_script =
    \\(() => {
    \\  try {
    \\    var i = document.querySelector('[name=cf-turnstile-response]');
    \\    if (i && i.value) return i.value;
    \\  } catch (e) {}
    \\  return '';
    \\})()
;

/// First Turnstile token in the session, or null.
pub fn token(session: *Session) ?[]const u8 {
    for (session.pages.items) |page| {
        if (page.replacement != null) continue;
        if (frameToken(&page.frame)) |t| return t;
    }
    return null;
}

pub fn hasToken(session: *Session) bool {
    return token(session) != null;
}

fn frameToken(frame: *Frame) ?[]const u8 {
    // A challenge frame carries its own copy of the response value, and it has
    // one before the host page does. Only the host document's input is what a
    // real site reads and submits, so a challenge frame is never the answer:
    // reporting `.solved` off it hands the caller a token the page never got.
    if (isChallengeFrame(frame) == false) {
        if (ownToken(frame)) |t| return t;
    }
    for (frame.child_frames.items) |child| {
        if (frameToken(child)) |t| return t;
    }
    return null;
}

// The script's return value comes straight back to Zig — nothing is written to
// the DOM, so the page cannot see that we looked.
fn ownToken(frame: *Frame) ?[]const u8 {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const v = ls.local.exec(token_script, "turnstile_token") catch return null;
    const value = v.toStringSlice() catch return null;
    if (value.len <= 10) return null;
    // Escape the local scope's arena; the caller outlives it.
    return frame.arena.dupe(u8, value) catch null;
}

/// True if any frame looks like a Turnstile challenge/widget host.
pub fn hasWidget(session: *Session) bool {
    for (session.pages.items) |page| {
        if (page.replacement != null) continue;
        if (frameHasWidget(&page.frame)) return true;
    }
    return false;
}

fn frameHasWidget(frame: *Frame) bool {
    if (isChallengeFrame(frame)) return true;
    if (queryOne(frame, ".cf-turnstile") != null) return true;
    // Deliberately NOT a bare `[data-sitekey]`: reCAPTCHA and hCaptcha use that
    // same attribute, but every click target and the token poll below are
    // Cloudflare-shaped, so matching it engaged the solver on widgets it can
    // never drive and burned the whole wait budget before reporting `.timeout`.
    // Turnstile's implicit render requires `.cf-turnstile`, and its explicit
    // one produces the iframe matched below, so nothing real is lost.
    if (queryOne(frame, "iframe[src*='turnstile']") != null) return true;
    if (queryOne(frame, "iframe[src*='challenges.cloudflare.com']") != null) return true;
    for (frame.child_frames.items) |child| {
        if (frameHasWidget(child)) return true;
    }
    return false;
}

/// Non-blocking counterpart of `Runner.solveTurnstile`, for the CDP / MCP /
/// agent paths where the event loop must keep serving commands. A
/// self-rescheduling scheduler task instead of a wait loop: each run does one
/// cheap check and hands control straight back.
pub const AutoSolve = struct {
    frame: *Frame,
    budget_ms: u32,
    clicks: u32 = 0,
    idle_polls: u32 = 0,

    // Give a widget this long to show up before concluding it's a normal page.
    const idle_poll_ms: u32 = 500;
    const max_idle_polls: u32 = 4;
    const click_interval_ms: u32 = 1_500;
    const max_clicks: u32 = 12;
    pub const default_timeout_ms: u32 = 30_000;

    /// Arm the solver for a freshly loaded main frame. No-op unless
    /// `--solve-captchas` is on (the default unless `--no-stealth` is used).
    pub fn start(frame: *Frame) void {
        if (frame._session.browser.app.config.solveCaptchas() == false) return;
        arm(frame, default_timeout_ms);
    }

    /// Arm regardless of config — an explicit request (`LP.solveCaptchas`).
    /// Returns immediately; the solve runs on the scheduler.
    pub fn arm(frame: *Frame, timeout_ms: u32) void {
        if (frame.parent != null) return;

        const self = frame.arena.create(AutoSolve) catch return;
        self.* = .{ .frame = frame, .budget_ms = timeout_ms };
        frame.js.scheduler.add(self, run, idle_poll_ms, .{ .name = "turnstile.autosolve" }) catch {};
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *AutoSolve = @ptrCast(@alignCast(ctx));
        const frame = self.frame;

        if (frameToken(frame) != null) {
            log.info(.browser, "turnstile token ready", .{ .clicks = self.clicks });
            return null;
        }

        if (frameHasWidget(frame) == false) {
            // Ordinary page: stop quickly, don't keep polling forever.
            self.idle_polls += 1;
            if (self.idle_polls >= max_idle_polls) return null;
            return self.spend(idle_poll_ms);
        }

        if (self.clicks >= max_clicks) {
            log.info(.browser, "turnstile unsolved", .{ .clicks = self.clicks });
            return null;
        }
        // First clicks stay inside challenge iframes; later ones also tap the
        // host widget (same escalation as Runner.solveTurnstile).
        walkFrame(frame, self.clicks >= 3);
        self.clicks += 1;
        return self.spend(click_interval_ms);
    }

    // Charge the next sleep against the timeout budget; null stops the task.
    fn spend(self: *AutoSolve, ms: u32) ?u32 {
        if (self.budget_ms <= ms) return null;
        self.budget_ms -= ms;
        return ms;
    }
};
