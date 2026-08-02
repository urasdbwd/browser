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
    } else {
        // Promote any existing token into document.title for wait helpers.
        promoteTokenTitle(frame);
        if (aggressive) {
            clickHostWidget(frame);
        }
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
    const x: f64 = 28;
    const y: f64 = 32;
    user_input.triggerMouseMove(frame, x, y) catch {};
    user_input.triggerMousePress(frame, x, y, user_input.mouse_button.main) catch {};
    user_input.triggerMouseRelease(frame, x, y, user_input.mouse_button.main, 1) catch {};
    actions.click(el.asNode(), frame) catch |err| {
        log.debug(.browser, "turnstile click", .{ .err = err });
    };
}

fn queryOne(frame: *Frame, sel: []const u8) ?*Node.Element {
    return Selector.querySelector(frame.document.asNode(), sel, frame) catch null;
}

fn promoteTokenTitle(frame: *Frame) void {
    const src =
        \\(() => {
        \\  try {
        \\    var i = document.querySelector('[name=cf-turnstile-response], textarea[name=cf-turnstile-response], input[name=cf-turnstile-response]');
        \\    if (i && i.value && i.value.length > 10 && document.title.indexOf('TOKEN:') !== 0) {
        \\      document.title = 'TOKEN:' + i.value.slice(0, 80);
        \\    }
        \\  } catch (e) {}
        \\  return true;
        \\})()
    ;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = ls.local.exec(src, "turnstile_promote") catch {};
}

/// Wait-script body: true once a Turnstile token is present.
pub const token_wait_script =
    \\(() => {
    \\  try {
    \\    if (document.title && document.title.indexOf('TOKEN:') === 0) return true;
    \\    var i = document.querySelector('[name=cf-turnstile-response], textarea[name=cf-turnstile-response], input[name=cf-turnstile-response]');
    \\    if (i && i.value && i.value.length > 10) {
    \\      document.title = 'TOKEN:' + i.value.slice(0, 80);
    \\      return true;
    \\    }
    \\  } catch (e) {}
    \\  return false;
    \\})()
;

pub fn hasToken(session: *Session) bool {
    for (session.pages.items) |page| {
        if (page.replacement != null) continue;
        if (frameHasToken(&page.frame)) return true;
    }
    return false;
}

fn frameHasToken(frame: *Frame) bool {
    promoteTokenTitle(frame);
    const src =
        \\(() => {
        \\  if (document.title && document.title.indexOf('TOKEN:') === 0) return true;
        \\  var i = document.querySelector('[name=cf-turnstile-response], textarea[name=cf-turnstile-response], input[name=cf-turnstile-response]');
        \\  return !!(i && i.value && i.value.length > 10);
        \\})()
    ;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const v = ls.local.exec(src, "turnstile_has_token") catch {
        // Fall through to children.
        for (frame.child_frames.items) |child| {
            if (frameHasToken(child)) return true;
        }
        return false;
    };
    if (v.toBool()) return true;
    for (frame.child_frames.items) |child| {
        if (frameHasToken(child)) return true;
    }
    return false;
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
    if (queryOne(frame, "[data-sitekey]") != null) return true;
    if (queryOne(frame, "iframe[src*='turnstile']") != null) return true;
    if (queryOne(frame, "iframe[src*='challenges.cloudflare.com']") != null) return true;
    for (frame.child_frames.items) |child| {
        if (frameHasWidget(child)) return true;
    }
    return false;
}
