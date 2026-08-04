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

// Synthetic user input driving the DOM: mouse, wheel, keyboard, focus
// navigation and text insertion. These are mostly fed by CDP's Input domain
// (src/cdp/domains/input.zig) and by EventManager's default activation
// behavior. Form submission itself lives on the Frame (it's a navigation
// concern); the activation paths here call into it.

const std = @import("std");
const lp = @import("lightpanda");
const builtin = @import("builtin");

const Frame = @import("../Frame.zig");
const js = @import("../js/js.zig");

const Node = @import("../webapi/Node.zig");
const Event = @import("../webapi/Event.zig");
const Element = @import("../webapi/Element.zig");
const TreeWalker = @import("../webapi/TreeWalker.zig");
const MouseEvent = @import("../webapi/event/MouseEvent.zig");
const PointerEvent = @import("../webapi/event/PointerEvent.zig");
const WheelEvent = @import("../webapi/event/WheelEvent.zig");
const KeyboardEvent = @import("../webapi/event/KeyboardEvent.zig");

const log = lp.log;
const IS_DEBUG = builtin.mode == .Debug;

// DOM MouseEvent.button values.
// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/button
pub const mouse_button = struct {
    pub const main: i32 = 0; // left
    pub const auxiliary: i32 = 1; // middle
    pub const secondary: i32 = 2; // right
    pub const fourth: i32 = 3; // back
    pub const fifth: i32 = 4; // forward
};

fn mouseButtonMask(button: i32) u16 {
    return switch (button) {
        mouse_button.main => 1,
        mouse_button.secondary => 2,
        mouse_button.auxiliary => 4,
        mouse_button.fourth => 8,
        mouse_button.fifth => 16,
        else => 0,
    };
}

pub const MouseModifiers = struct {
    alt: bool = false,
    control: bool = false,
    meta: bool = false,
    shift: bool = false,
};

fn dispatchMouseEventOnWithModifiers(
    frame: *Frame,
    target: *Element,
    comptime typ: []const u8,
    x: f64,
    y: f64,
    button: i32,
    buttons: u16,
    detail: u32,
    modifiers: MouseModifiers,
) !bool {
    // mouseenter/mouseleave neither bubble nor cancel.
    const enters = comptime std.mem.eql(u8, typ, "mouseenter") or
        std.mem.eql(u8, typ, "mouseleave");
    const event: *MouseEvent = try .initTrusted(comptime .wrap(typ), .{
        .bubbles = !enters,
        .cancelable = !enters,
        .composed = !enters,
        .clientX = x,
        .clientY = y,
        .button = button,
        .buttons = buttons,
        .detail = detail,
        .altKey = modifiers.alt,
        .ctrlKey = modifiers.control,
        .metaKey = modifiers.meta,
        .shiftKey = modifiers.shift,
    }, frame);
    event.asEvent().acquireRef();
    defer _ = event.asEvent().releaseRef(frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), event.asEvent());
    return event.asEvent()._prevent_default;
}

fn dispatchPointerEventOnWithModifiers(
    frame: *Frame,
    target: *Element,
    comptime typ: []const u8,
    x: f64,
    y: f64,
    button: i32,
    buttons: u16,
    pressure: f64,
    modifiers: MouseModifiers,
) !bool {
    const enters = comptime std.mem.eql(u8, typ, "pointerenter");
    const event = try PointerEvent.initTrusted(typ, .{
        .bubbles = !enters,
        .cancelable = !enters,
        .composed = !enters,
        .clientX = x,
        .clientY = y,
        .button = button,
        .buttons = buttons,
        .altKey = modifiers.alt,
        .ctrlKey = modifiers.control,
        .metaKey = modifiers.meta,
        .shiftKey = modifiers.shift,
        .pointerId = 1,
        .pointerType = "mouse",
        .pressure = pressure,
        .isPrimary = true,
    }, frame);
    event.asEvent().acquireRef();
    defer _ = event.asEvent().releaseRef(frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), event.asEvent());
    return event.asEvent()._prevent_default;
}

// Dispatch a single trusted mouse event of the given type on `target`, carrying
// the pressed button and pointer position. `detail` is the click count (used for
// click/dblclick); 0 for events where it does not apply.
fn dispatchMouseEventOn(frame: *Frame, target: *Element, comptime typ: []const u8, x: f64, y: f64, button: i32, detail: u32) !void {
    _ = try dispatchMouseEventOnWithModifiers(
        frame,
        target,
        typ,
        x,
        y,
        button,
        0,
        detail,
        .{},
    );
}

pub const MouseDown = struct {
    target: *Element,
    button: i32,
    pointerdown_prevented: bool,
};

// over/enter describe a pointer *entering* an element. Re-firing them for every
// press or move on an element the pointer never left makes hover menus,
// tooltips and enter-counters see phantom entries.
fn enterTarget(
    frame: *Frame,
    target: *Element,
    x: f64,
    y: f64,
    buttons: u16,
    modifiers: MouseModifiers,
    with_pointer_events: bool,
) !void {
    if (frame._hover_element == target) {
        return;
    }
    frame._hover_element = target;
    if (with_pointer_events) {
        _ = try dispatchPointerEventOnWithModifiers(frame, target, "pointerover", x, y, -1, buttons, 0, modifiers);
        _ = try dispatchPointerEventOnWithModifiers(frame, target, "pointerenter", x, y, -1, buttons, 0, modifiers);
    }
    _ = try dispatchMouseEventOnWithModifiers(frame, target, "mouseover", x, y, mouse_button.main, buttons, 0, modifiers);
    _ = try dispatchMouseEventOnWithModifiers(frame, target, "mouseenter", x, y, mouse_button.main, buttons, 0, modifiers);
}

fn triggerMousePressOn(
    frame: *Frame,
    target: *Element,
    x: f64,
    y: f64,
    button: i32,
    buttons: u16,
    detail: u32,
    modifiers: MouseModifiers,
) !MouseDown {
    const buttons_before = buttons & ~mouseButtonMask(button);
    try enterTarget(frame, target, x, y, buttons_before, modifiers, true);

    const pointerdown_prevented = try dispatchPointerEventOnWithModifiers(frame, target, "pointerdown", x, y, button, buttons, 0.5, modifiers);
    if (!pointerdown_prevented) {
        const mousedown_prevented = try dispatchMouseEventOnWithModifiers(frame, target, "mousedown", x, y, button, buttons, detail, modifiers);
        if (!mousedown_prevented) {
            try focusForMouseDown(frame, target);
        }
    }

    return .{
        .target = target,
        .button = button,
        .pointerdown_prevented = pointerdown_prevented,
    };
}

fn triggerMouseReleaseOn(
    frame: *Frame,
    target: *Element,
    x: f64,
    y: f64,
    button: i32,
    buttons: u16,
    detail: u32,
    modifiers: MouseModifiers,
    down: ?MouseDown,
) !void {
    _ = try dispatchPointerEventOnWithModifiers(frame, target, "pointerup", x, y, button, buttons, 0, modifiers);
    if (down == null or !down.?.pointerdown_prevented) {
        _ = try dispatchMouseEventOnWithModifiers(frame, target, "mouseup", x, y, button, buttons, detail, modifiers);
    }

    const pressed = down orelse return;
    if (pressed.target != target or pressed.button != button) return;

    switch (button) {
        mouse_button.main => {
            _ = try dispatchMouseEventOnWithModifiers(frame, target, "click", x, y, button, buttons, detail, modifiers);
            if (detail == 2) {
                _ = try dispatchMouseEventOnWithModifiers(frame, target, "dblclick", x, y, button, buttons, detail, modifiers);
            }
        },
        mouse_button.auxiliary => _ = try dispatchMouseEventOnWithModifiers(frame, target, "auxclick", x, y, button, buttons, detail, modifiers),
        mouse_button.secondary => _ = try dispatchMouseEventOnWithModifiers(frame, target, "contextmenu", x, y, button, buttons, detail, modifiers),
        else => {},
    }
}

/// Dispatch a left-click sequence to an already-resolved DOM target.
///
/// Render clients perform layout and hit-testing. Re-running elementFromPoint
/// with Lightpanda's synthetic layout could select a different element.
pub fn triggerMouseClickOn(
    frame: *Frame,
    target: *Element,
    x: f64,
    y: f64,
    modifiers: MouseModifiers,
) !void {
    const down = try triggerMousePressOn(frame, target, x, y, mouse_button.main, 1, 1, modifiers);
    try triggerMouseReleaseOn(frame, target, x, y, mouse_button.main, 0, 1, modifiers, down);
}

// Exactly one of these kinds may be transported per real event. In particular
// `contextmenu` is only ever produced here, from a client that observed a real
// one; the secondary-button synthesis in triggerMouseReleaseOn belongs to CDP,
// whose clients send raw press/release pairs and never a contextmenu of their
// own. Routing mouseup through the release sequence would make both fire.
pub const MouseEventKind = enum {
    mousedown,
    mouseup,
    mousemove,
    mouseover,
    mouseout,
    mouseenter,
    mouseleave,
    contextmenu,
    dblclick,
};

/// Dispatch exactly one trusted mouse event to an already-resolved DOM target.
///
/// Same contract as triggerMouseClickOn: the render client owns layout and
/// hit-testing, so this deliberately does not re-run elementFromPoint. Callers
/// that want the full press/release/activation sequence use triggerMouseClickOn.
pub fn triggerMouseEventOn(
    frame: *Frame,
    target: *Element,
    kind: MouseEventKind,
    x: f64,
    y: f64,
    button: i32,
    buttons: u16,
    detail: u32,
    modifiers: MouseModifiers,
) !void {
    switch (kind) {
        inline else => |k| {
            const prevented = try dispatchMouseEventOnWithModifiers(
                frame,
                target,
                @tagName(k),
                x,
                y,
                button,
                buttons,
                detail,
                modifiers,
            );
            // A real mousedown focuses the element it lands on. Without this a
            // transported mousedown/mouseup pair leaves focus on <body> and
            // every keystroke after a click goes to the wrong place.
            if (comptime k == .mousedown) {
                if (!prevented) {
                    try focusForMouseDown(frame, target);
                }
            }
            if (comptime k == .mouseover or k == .mouseenter) {
                frame._hover_element = target;
            }
            if (comptime k == .mouseout or k == .mouseleave) {
                if (frame._hover_element == target) {
                    frame._hover_element = null;
                }
            }
        },
    }
}

fn isSubmitButton(element: *Element) bool {
    return Element.Html.Form.isSubmitButton(element);
}

// Keep the legacy stateless helpers for non-CDP callers.
pub fn triggerMousePress(frame: *Frame, x: f64, y: f64, button: i32) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
    try dispatchMouseEventOn(frame, target, "mousedown", x, y, button, 0);
    try focusEditingHostForMouseDown(frame, target);
}

pub fn triggerMouseMove(frame: *Frame, x: f64, y: f64) !void {
    return triggerMouseMoveWithOptions(frame, x, y, 0, .{});
}

pub fn triggerMouseRelease(frame: *Frame, x: f64, y: f64, button: i32, click_count: i32) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
    const detail: u32 = if (click_count > 0) @intCast(click_count) else 1;

    try dispatchMouseEventOn(frame, target, "mouseup", x, y, button, detail);
    switch (button) {
        mouse_button.main => {
            try dispatchMouseEventOn(frame, target, "click", x, y, button, detail);
            if (click_count == 2) {
                try dispatchMouseEventOn(frame, target, "dblclick", x, y, button, detail);
            }
        },
        mouse_button.auxiliary => try dispatchMouseEventOn(frame, target, "auxclick", x, y, button, detail),
        mouse_button.secondary => try dispatchMouseEventOn(frame, target, "contextmenu", x, y, button, detail),
        else => {},
    }
}

pub fn triggerMouseWheel(frame: *Frame, x: f64, y: f64, delta_x: f64, delta_y: f64) !void {
    return triggerMouseWheelWithOptions(frame, x, y, delta_x, delta_y, 0, .{});
}

pub fn triggerMousePressWithState(
    frame: *Frame,
    x: f64,
    y: f64,
    button: i32,
    buttons: u16,
    click_count: i32,
    modifiers: MouseModifiers,
) !?MouseDown {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return null;
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse press", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .button = button,
            .type = frame._type,
        });
    }
    const detail: u32 = if (click_count > 0) @intCast(click_count) else 1;
    const down = try triggerMousePressOn(frame, target, x, y, button, buttons, detail, modifiers);
    return down;
}

pub fn triggerMouseMoveWithOptions(frame: *Frame, x: f64, y: f64, buttons: u16, modifiers: MouseModifiers) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse move", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .type = frame._type,
        });
    }

    _ = try dispatchMouseEventOnWithModifiers(frame, target, "mousemove", x, y, mouse_button.main, buttons, 0, modifiers);
    try enterTarget(frame, target, x, y, buttons, modifiers, false);
}

pub fn triggerMouseReleaseWithState(
    frame: *Frame,
    x: f64,
    y: f64,
    button: i32,
    buttons: u16,
    click_count: i32,
    modifiers: MouseModifiers,
    down: ?MouseDown,
) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse release", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .button = button,
            .type = frame._type,
        });
    }

    const detail: u32 = if (click_count > 0) @intCast(click_count) else 1;
    try triggerMouseReleaseOn(frame, target, x, y, button, buttons, detail, modifiers, down);
}

pub fn triggerMouseWheelWithOptions(
    frame: *Frame,
    x: f64,
    y: f64,
    delta_x: f64,
    delta_y: f64,
    buttons: u16,
    modifiers: MouseModifiers,
) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse wheel", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .delta_x = delta_x,
            .delta_y = delta_y,
            .type = frame._type,
        });
    }
    return triggerMouseWheelOn(frame, target, x, y, delta_x, delta_y, buttons, modifiers);
}

/// Wheel against an already-resolved target. Render clients hit-test in the
/// real browser, so they must not go through elementFromPoint.
pub fn triggerMouseWheelOn(
    frame: *Frame,
    target: *Element,
    x: f64,
    y: f64,
    delta_x: f64,
    delta_y: f64,
    buttons: u16,
    modifiers: MouseModifiers,
) !void {
    const wheel_event: *WheelEvent = try .initTrusted("wheel", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
        .buttons = buttons,
        .altKey = modifiers.alt,
        .ctrlKey = modifiers.control,
        .metaKey = modifiers.meta,
        .shiftKey = modifiers.shift,
        .deltaX = delta_x,
        .deltaY = delta_y,
    }, frame);

    // Keep the event alive past dispatch so we can read _prevent_default.
    wheel_event.asEvent().acquireRef();
    defer _ = wheel_event.asEvent().releaseRef(frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), wheel_event.asEvent());

    if (wheel_event.asEvent()._prevent_default) {
        return;
    }

    // Apply the scroll and fire a trusted scroll event, mirroring WebDriver wheel.
    // CDP deltas are untrusted, so guard NaN and saturate the addition.
    const new_left: i32 = @as(i32, @intCast(target.getScrollLeft(frame))) +| deltaToScroll(delta_x);
    const new_top: i32 = @as(i32, @intCast(target.getScrollTop(frame))) +| deltaToScroll(delta_y);
    try target.setScrollLeft(new_left, frame);
    try target.setScrollTop(new_top, frame);

    const scroll_event = try Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), scroll_event);
}

fn deltaToScroll(d: f64) i32 {
    if (std.math.isNan(d)) return 0;
    return @intFromFloat(std.math.clamp(d, std.math.minInt(i32), std.math.maxInt(i32)));
}

// callback when the "click" event reaches the frame.
// Whether the element has a click activation behavior that handleClick
// implements.
fn hasClickActivationBehavior(node: *Node) bool {
    const element = node.is(Element) orelse return false;
    const html_element = element.is(Element.Html) orelse return false;
    return switch (html_element.typed()) {
        .anchor => element.getAttributeSafe(comptime .wrap("href")) != null,
        .input, .button, .select, .textarea, .label => true,
        .generic => |generic| generic._tag == .summary,
        else => false,
    };
}

// Clicks on editable content are for editing: they don't activate the
// element or any enclosing link.
// "contenteditable" is 15 bytes — past the comptime SSO limit — so the
// String wrap runs at runtime, mirroring Html.getIsContentEditable.
fn isEditingHost(node: *Node) bool {
    const element = node.is(Element) orelse return false;
    const value = element.getAttributeSafe(.wrap("contenteditable")) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "false") == false;
}

fn editingHostForMouseDown(target: *Element) ?*Element {
    var node: ?*Node = target.asNode();
    var editable: ?*Node = null;
    while (node) |n| : (node = n._parent) {
        if (isEditingHost(n)) {
            editable = n;
            break;
        }
    }
    var host = editable orelse return null;
    while (host._parent) |parent| {
        if (!isEditingHost(parent)) {
            break;
        }
        host = parent;
    }
    return host.is(Element);
}

// A mousedown on editable content focuses its editing host: the outermost
// element of the contiguous editable chain containing the target.
pub fn focusEditingHostForMouseDown(frame: *Frame, target: *Element) !void {
    const host = editingHostForMouseDown(target) orelse return;
    try host.focus(frame);
}

fn isClickFocusable(element: *Element) bool {
    if (element.getAttributeSafe(comptime .wrap("tabindex")) != null) {
        return true;
    }
    return switch (element.getTag()) {
        .button, .select, .textarea, .summary => true,
        .input => element.as(Element.Html.Input)._input_type != .hidden,
        .anchor, .area => element.getAttributeSafe(comptime .wrap("href")) != null,
        else => false,
    };
}

fn focusForMouseDown(frame: *Frame, target: *Element) !void {
    var node: ?*Node = target.asNode();
    while (node) |current| : (node = current._parent) {
        if (isEditingHost(current)) {
            const host = editingHostForMouseDown(target) orelse return;
            return host.focus(frame);
        }
        const element = current.is(Element) orelse continue;
        if (!element.isDisabled() and isClickFocusable(element)) {
            return element.focus(frame);
        }
    }
}

// Per the DOM dispatch algorithm, a click's activation target is the event
// target itself when it has activation behavior, otherwise — for bubbling
// events only — the nearest ancestor that has one.
pub fn findClickActivationTarget(target: *Node, bubbles: bool) ?*Node {
    if (isEditingHost(target)) {
        return null;
    }
    if (hasClickActivationBehavior(target)) {
        return target;
    }
    if (!bubbles) {
        return null;
    }
    var node = target._parent;
    while (node) |n| : (node = n._parent) {
        if (isEditingHost(n)) {
            return null;
        }
        if (hasClickActivationBehavior(n)) {
            return n;
        }
    }
    return null;
}

fn runJavascriptUrl(frame: *Frame, source: []const u8) !void {
    const arena = try frame.getArena(.tiny, "javascript-url");
    errdefer arena.release();

    const task = try arena.create(JavascriptUrlTask);
    task.* = .{
        .frame = frame,
        .arena = arena,
        // TODO: the URL body should be percent-decoded; hrefs written in
        // markup rarely are.
        .source = try arena.dupe(u8, source),
    };
    try frame.js.scheduler.add(task, JavascriptUrlTask.run, 0, .{
        .name = "javascript-url",
        .finalizer = JavascriptUrlTask.finalize,
    });
}

const JavascriptUrlTask = struct {
    frame: *Frame,
    arena: *lp.Arena,
    source: []const u8,

    fn run(ptr: *anyopaque) !?u32 {
        const self: *JavascriptUrlTask = @ptrCast(@alignCast(ptr));
        const frame = self.frame;
        defer self.deinit();

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const script = ls.local.compile(self.source, "javascript:") catch |err| {
            log.warn(.browser, "javascript-url compile", .{ .err = err, .type = frame._type, .url = frame.url });
            return null;
        };
        _ = script.run() catch |err| {
            log.warn(.browser, "javascript-url run", .{ .err = err, .type = frame._type, .url = frame.url });
        };
        return null;
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *JavascriptUrlTask = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn deinit(self: *JavascriptUrlTask) void {
        self.arena.release();
    }
};

pub fn handleClick(frame: *Frame, target: *Node, event: *Event) !void {
    // TODO: Also support <area> elements when implement
    const element = target.is(Element) orelse return;
    const html_element = element.is(Element.Html) orelse return;
    const mouse_event = event.is(MouseEvent) orelse return;
    const focus_on_click = mouse_event._proto.getDetail() == 0;

    switch (html_element.typed()) {
        .anchor => |anchor| {
            const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
            if (href.len == 0) {
                return;
            }

            if (std.mem.startsWith(u8, href, "javascript:")) {
                // Navigating to a javascript: URL evaluates the script in the
                // node's frame as a queued task. (A string completion value
                // would replace the document; we ignore results.)
                return runJavascriptUrl(target.ownerFrame(frame), href["javascript:".len..]);
            }

            if (try element.hasAttribute(comptime .wrap("download"), frame)) {
                log.warn(.browser, "a.download", .{ .type = frame._type, .url = frame.url });
                return;
            }

            const target_frame = blk: {
                const target_name = anchor.getTarget();
                if (target_name.len == 0) {
                    break :blk target.ownerFrame(frame);
                }
                break :blk frame.resolveTargetFrame(target_name) orelse {
                    log.warn(.not_implemented, "target", .{ .type = frame._type, .url = frame.url, .target = target_name });
                    return;
                };
            };

            if (focus_on_click) try element.focus(frame);
            try frame.scheduleNavigation(href, .{
                .reason = .script,
                .kind = .{ .push = null },
            }, .{ .anchor = target_frame });
        },
        .input => |input| {
            if (focus_on_click) try element.focus(frame);
            // Per HTML §4.10.18.6.4 "Image Button state (type=image)", clicking an
            // image button submits its form. The form-data set already gets the
            // submitter's coordinate fields appended via FormData.collectForm
            // (see src/browser/webapi/net/FormData.zig).
            if (input._input_type == .submit or input._input_type == .image) {
                return frame.submitForm(element, input.getForm(frame), .{});
            }
        },
        .button => |button| {
            if (focus_on_click) try element.focus(frame);
            if (std.mem.eql(u8, button.getType(), "submit")) {
                return frame.submitForm(element, button.getForm(frame), .{});
            }
        },
        .select, .textarea => if (focus_on_click) try element.focus(frame),
        .label => |label| {
            // Per HTML §4.10.4 "The label element", a label's activation
            // behavior is to run the synthetic click activation steps on the
            // labeled control. Mirrors Chrome's HTMLLabelElement::DefaultEventHandler.
            const control = label.getControl(frame) orelse return;
            const control_html = control.is(Element.Html) orelse return;
            try control_html.click(frame);
        },
        .generic => |generic| {
            switch (generic._tag) {
                .summary => {
                    const parent_el = target.parentElement() orelse return;
                    const details = parent_el.is(Element.Html.Details) orelse return;
                    var maybe_prev = element.previousElementSibling();
                    while (maybe_prev) |prev| {
                        if (prev.getTag() == .summary) {
                            // we found a summary element before the clicked one
                            return;
                        }
                        maybe_prev = prev.previousElementSibling();
                    }
                    try details.setOpen(!details.getOpen(), frame);
                },
                else => {},
            }
        },
        else => {},
    }
}

pub fn triggerKeyboard(frame: *Frame, keyboard_event: *KeyboardEvent) !bool {
    const event = keyboard_event.asEvent();
    // Dispatch to the effective active element. When nothing is explicitly
    // focused this resolves to <body> (matching `document.activeElement`), so
    // the keydown still fires and its default action — e.g. sequential focus
    // navigation on Tab — can run.
    const element = frame.window._document.getActiveElement() orelse {
        event.deinit(frame._page);
        return false;
    };

    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame keydown", .{
            .url = frame.url,
            .node = element,
            .key = keyboard_event._key,
            .type = frame._type,
        });
    }
    event.acquireRef();
    defer _ = event.releaseRef(frame._page);
    try frame._event_manager.dispatch(element.asEventTarget(), event);
    return event._prevent_default;
}

fn activateSubmitButton(frame: *Frame, button: *Element) !void {
    if (button.isDisabled()) {
        return;
    }
    return dispatchMouseEventOn(frame, button, "click", 0, 0, mouse_button.main, 0);
}

fn blocksImplicitSubmission(input: *Element.Html.Input) bool {
    return switch (input._input_type) {
        .text, .search, .tel, .url, .email, .password, .date, .month, .week, .time, .@"datetime-local", .number => true,
        else => false,
    };
}

fn implicitlySubmitInput(frame: *Frame, input: *Element.Html.Input) !void {
    const form = input.getForm(frame) orelse return;

    var controls = form.iterator(frame);
    var blocking_fields: usize = 0;
    while (controls.next()) |control| {
        if (isSubmitButton(control)) {
            return activateSubmitButton(frame, control);
        }
        if (control.is(Element.Html.Input)) |candidate| {
            if (blocksImplicitSubmission(candidate)) {
                blocking_fields += 1;
            }
        }
    }

    if (blocking_fields <= 1) {
        return form.requestSubmit(null, frame);
    }
}

pub fn handleKeydown(frame: *Frame, target: *Node, event: *Event) !void {
    const keyboard_event = event.is(KeyboardEvent) orelse return;
    const key = keyboard_event.getKey();

    if (key == .Dead) {
        return;
    }

    if (key == .Tab) {
        // tab -> forward, shift+tab -> backwards
        return moveFocus(frame, keyboard_event.getShiftKey() == false);
    }

    if (target.is(Element.Html.Input)) |input| {
        if (key == .Enter) {
            if (input._input_type == .submit or input._input_type == .image) {
                return activateSubmitButton(frame, input.asElement());
            }
            if (blocksImplicitSubmission(input)) {
                return implicitlySubmitInput(frame, input);
            }
            return;
        }

        // Don't handle text input for radio/checkbox
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        // Handle printable characters
        if (key.isPrintable() and !keyboard_event._skip_text_insertion) {
            try input.innerInsert(key.asString(), frame);
        }
        return;
    }

    if (target.is(Element.Html.Button)) |button| {
        if (key == .Enter and isSubmitButton(button.asElement())) {
            return activateSubmitButton(frame, button.asElement());
        }
        return;
    }

    if (target.is(Element.Html.TextArea)) |textarea| {
        if (keyboard_event._skip_text_insertion) {
            return;
        }
        // zig fmt: off
        const append =
            if (key == .Enter) "\n"
            else if (key.isPrintable()) key.asString()
            else return
        ;
        // zig fmt: on
        return textarea.innerInsert(append, frame);
    }
}

// Sequential focus navigation: move `document.activeElement` to the next (Tab)
// or previous (Shift+Tab) focusable element, firing the usual blur/focus events
// via `Element.focus`. The order is fully determined by tabindex + document
// position, so no layout is needed:
//   1. elements with a positive tabindex, in ascending tabindex order;
//   2. then elements with tabindex 0 (or a natively-focusable default), in
//      document order.
// Ties within a group break on document order, and Tab wraps around at the ends.
// https://html.spec.whatwg.org/multipage/interaction.html#sequential-focus-navigation
fn moveFocus(frame: *Frame, forward: bool) !void {
    const document = frame.document;
    const current = document._active_element;

    const current_tab_index = blk: {
        const cur = current orelse break :blk 0;
        const current_html = cur.is(Element.Html) orelse break :blk 0;
        break :blk current_html.getTabIndex();
    };

    // Single document-order pass tracking two candidates:
    //   edge   — the global first (forward) / last (backward) focusable element,
    //            used to wrap around when `current` is at an end, or as the
    //            landing spot when nothing is focused yet.
    //   chosen — the closest focusable element strictly past `current` in the
    //            travel direction.
    var edge: ?*Element = null;
    var edge_tab_index: i32 = 0;

    var chosen: ?*Element = null;
    var chosen_tab_index: i32 = 0;

    var tw = TreeWalker.Full.Elements.init(document.asNode(), .{});
    while (tw.next()) |candidate| {
        if (candidate.isDisabled()) {
            continue;
        }
        if (candidate.is(Element.Html) == null) {
            continue;
        }

        const candidate_tab_index = blk: {
            if (candidate.getAttributeSafe(comptime .wrap("tabindex"))) |attr| {
                if (Element.Html.parseInteger(attr)) |tab_index| {
                    if (tab_index < 0) {
                        continue;
                    }
                    break :blk tab_index;
                }
                break :blk 0;
            }

            // no tab index, maybe this item isn't focusable..
            const focusable = switch (candidate.getTag()) {
                .button, .select, .textarea, .iframe => true,
                .input => candidate.as(Element.Html.Input)._input_type != .hidden,
                .anchor, .area => candidate.getAttributeSafe(comptime .wrap("href")) != null,
                else => false,
            };
            if (focusable == false) {
                continue;
            }

            break :blk 0;
        };

        if (edge == null or focusOrderBefore(candidate, candidate_tab_index, edge.?, edge_tab_index) == forward) {
            edge = candidate;
            edge_tab_index = candidate_tab_index;
        }

        const cur = current orelse continue;

        if (candidate == cur) {
            continue;
        }

        const past = if (forward) focusOrderBefore(cur, current_tab_index, candidate, candidate_tab_index) else focusOrderBefore(candidate, candidate_tab_index, cur, current_tab_index);
        if (!past) {
            continue;
        }
        if (chosen == null or focusOrderBefore(candidate, candidate_tab_index, chosen.?, chosen_tab_index) == forward) {
            chosen = candidate;
            chosen_tab_index = candidate_tab_index;
        }
    }

    const next = chosen orelse edge orelse return;
    try next.focus(frame);
}

// Orders two focusable elements by sequential focus navigation order: positive
// tabindex first (ascending), then tabindex 0, ties broken by document order.
fn focusOrderBefore(a: *Element, a_tab_index: i32, b: *Element, b_tab_index: i32) bool {
    if (a_tab_index == b_tab_index) {
        // Equal tabindex → document order: `a` precedes `b` when `b` follows `a`.
        const FOLLOWING: u16 = 0x04;
        return (a.asNode().compareDocumentPosition(b.asNode()) & FOLLOWING) != 0;
    }

    const group_a: u8 = if (a_tab_index > 0) 0 else 1;
    const group_b: u8 = if (b_tab_index > 0) 0 else 1;
    if (group_a != group_b) {
        return group_a < group_b;
    }

    return a_tab_index < b_tab_index;
}

// insertText is a shortcut to insert text into the active element.
pub fn insertText(frame: *Frame, v: []const u8) !void {
    const html_element = frame.document._active_element orelse return;

    if (html_element.is(Element.Html.Input)) |input| {
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        return input.innerInsert(v, frame);
    }

    if (html_element.is(Element.Html.TextArea)) |textarea| {
        return textarea.innerInsert(v, frame);
    }
}

const testing = @import("../../cdp/testing.zig");

test "user input: known-target click dispatches pointer and mouse sequence before activation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    });
    try testing.waitForPage(bc);

    var scope: lp.js.Local.Scope = undefined;
    frame.js.localScope(&scope);
    defer scope.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&scope.local);
    defer try_catch.deinit();

    try testing.expect((try triggerMousePressWithState(frame, -1, -1, mouse_button.main, 1, 1, .{})) == null);

    _ = try scope.local.compileAndRun(
        \\document.body.innerHTML =
        \\  '<input id="old"><button id="button"><span id="target">hit</span></button>' +
        \\  '<div id="generic" tabindex="0"><span id="generic-target">generic</span></div>' +
        \\  '<div id="editor" contenteditable><span id="editor-target">edit</span></div>';
        \\const old = document.getElementById('old');
        \\const button = document.getElementById('button');
        \\const target = document.getElementById('target');
        \\window.clickLog = [];
        \\window.cancelPointerDown = false;
        \\window.cancelMouseDown = false;
        \\for (const type of [
        \\  'pointerover', 'pointerenter', 'mouseover', 'mouseenter',
        \\  'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'
        \\]) {
        \\  target.addEventListener(type, event => {
        \\    clickLog.push({
        \\      type, target: event.target.id, trusted: event.isTrusted,
        \\      pointer: event instanceof PointerEvent,
        \\      x: event.clientX, y: event.clientY,
        \\      button: event.button, buttons: event.buttons, detail: event.detail,
        \\      alt: event.altKey, ctrl: event.ctrlKey,
        \\      meta: event.metaKey, shift: event.shiftKey,
        \\      active: document.activeElement.id,
        \\      pointerId: event.pointerId, pointerType: event.pointerType,
        \\      primary: event.isPrimary, pressure: event.pressure
        \\    });
        \\    if (type === 'pointerdown' && cancelPointerDown) event.preventDefault();
        \\    if (type === 'mousedown' && cancelMouseDown) event.preventDefault();
        \\  });
        \\}
        \\button.addEventListener('focus', () => clickLog.push({type: 'focus'}));
        \\old.focus();
    , null);

    try triggerMouseClickOn(frame, frame.document.getElementById("target", frame).?, 37, 42, .{
        .alt = true,
        .control = true,
        .meta = true,
        .shift = true,
    });

    try testing.expect((try scope.local.compileAndRun(
        \\clickLog.map(event => event.type).join(',') ===
        \\  'pointerover,pointerenter,mouseover,mouseenter,pointerdown,mousedown,focus,pointerup,mouseup,click' &&
        \\clickLog.filter(event => event.type !== 'focus').every(event =>
        \\  event.target === 'target' && event.trusted &&
        \\  event.x === 37 && event.y === 42 &&
        \\  event.alt && event.ctrl && event.meta && event.shift) &&
        \\clickLog.filter(event => event.pointer).every(event =>
        \\  event.pointerId === 1 && event.pointerType === 'mouse' && event.primary) &&
        \\clickLog[0].pointer && clickLog[0].button === -1 && clickLog[0].buttons === 0 &&
        \\clickLog[4].pointer && clickLog[4].button === 0 && clickLog[4].buttons === 1 &&
        \\clickLog[4].detail === 0 && clickLog[4].pressure === 0.5 &&
        \\!clickLog[5].pointer && clickLog[5].buttons === 1 && clickLog[5].detail === 1 &&
        \\clickLog[5].active === 'old' &&
        \\clickLog[7].active === 'button' &&
        \\clickLog[8].buttons === 0 && clickLog[8].detail === 1 &&
        \\clickLog[9].buttons === 0 && clickLog[9].detail === 1 &&
        \\document.activeElement === button
    , null)).isTrue());

    _ = try scope.local.compileAndRun(
        \\clickLog = [];
        \\cancelMouseDown = true;
        \\old.focus();
    , null);
    try triggerMouseClickOn(frame, frame.document.getElementById("target", frame).?, 5, 6, .{});

    // The pointer never left #target, so over/enter do not fire a second time.
    try testing.expect((try scope.local.compileAndRun(
        \\clickLog.map(event => event.type).join(',') ===
        \\  'pointerdown,mousedown,pointerup,mouseup,click' &&
        \\clickLog[1].active === 'old' &&
        \\clickLog[2].active === 'old' &&
        \\document.activeElement === old
    , null)).isTrue());

    _ = try scope.local.compileAndRun(
        \\clickLog = [];
        \\cancelMouseDown = false;
        \\cancelPointerDown = true;
        \\old.focus();
    , null);
    try triggerMouseClickOn(frame, frame.document.getElementById("target", frame).?, 7, 8, .{});

    try testing.expect((try scope.local.compileAndRun(
        \\clickLog.map(event => event.type).join(',') ===
        \\  'pointerdown,pointerup,click' &&
        \\clickLog[0].active === 'old' &&
        \\clickLog[1].active === 'old' &&
        \\clickLog[2].active === 'old' &&
        \\document.activeElement === old
    , null)).isTrue());

    _ = try scope.local.compileAndRun("cancelPointerDown = false", null);
    try triggerMouseClickOn(frame, frame.document.getElementById("generic-target", frame).?, 0, 0, .{});
    try testing.expect((try scope.local.compileAndRun(
        "document.activeElement.id === 'generic'",
        null,
    )).isTrue());

    try triggerMouseClickOn(frame, frame.document.getElementById("editor-target", frame).?, 0, 0, .{});
    try testing.expect((try scope.local.compileAndRun(
        "document.activeElement.id === 'editor'",
        null,
    )).isTrue());
}
