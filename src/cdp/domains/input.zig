// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const std = @import("std");
const CDP = @import("../CDP.zig");
const Frame = @import("../../browser/Frame.zig");

const dom_button = Frame.user_input.mouse_button;

const MouseState = struct {
    cdp: ?*CDP = null,
    frame: ?*Frame = null,
    loader_id: u32 = 0,
    buttons: u16 = 0,
    down: [5]?Frame.user_input.MouseDown = .{null} ** 5,
};

threadlocal var mouse_state: MouseState = .{};

fn currentMouseState(cmd: *CDP.Command, frame: *Frame) *MouseState {
    if (mouse_state.cdp != cmd.cdp or mouse_state.frame != frame or mouse_state.loader_id != frame._loader_id) {
        mouse_state = .{
            .cdp = cmd.cdp,
            .frame = frame,
            .loader_id = frame._loader_id,
        };
    }
    return &mouse_state;
}

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        dispatchKeyEvent,
        dispatchMouseEvent,
        insertText,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .dispatchKeyEvent => return dispatchKeyEvent(cmd),
        .dispatchMouseEvent => return dispatchMouseEvent(cmd),
        .insertText => return insertText(cmd),
    }
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-dispatchKeyEvent
fn dispatchKeyEvent(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        type: Type,
        key: []const u8 = "",
        code: ?[]const u8 = null,
        text: []const u8 = "",
        modifiers: u4 = 0,
        autoRepeat: bool = false,
        location: u32 = 0,
        // Many optional parameters are not implemented yet, see documentation url.

        const Type = enum {
            keyDown,
            keyUp,
            rawKeyDown,
            char,
        };
    })) orelse return error.InvalidParams;

    try cmd.sendResult(null, .{});

    const bc = cmd.browser_context orelse return;
    const frame = bc.mainFrame() orelse return;

    const KeyboardEvent = @import("../../browser/webapi/event/KeyboardEvent.zig");
    const keyboard_event = try KeyboardEvent.initTrusted(switch (params.type) {
        .keyDown, .rawKeyDown => comptime .wrap("keydown"),
        .keyUp => comptime .wrap("keyup"),
        .char => comptime .wrap("keypress"),
    }, .{
        .key = if (params.type == .char and params.key.len == 0) params.text else params.key,
        .code = params.code,
        .location = params.location,
        .repeat = params.autoRepeat,
        .altKey = params.modifiers & 1 == 1,
        .ctrlKey = params.modifiers & 2 == 2,
        .metaKey = params.modifiers & 4 == 4,
        .shiftKey = params.modifiers & 8 == 8,
    }, frame);
    keyboard_event._skip_text_insertion = params.type == .rawKeyDown;
    const prevented = try Frame.user_input.triggerKeyboard(frame, keyboard_event);
    if (params.type == .char and !prevented and params.text.len > 0) {
        try Frame.user_input.insertText(frame, params.text);
    }
    // result already sent
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-dispatchMouseEvent
fn dispatchMouseEvent(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        x: f64,
        y: f64,
        type: Type,
        button: Button = .none,
        buttons: ?u16 = null,
        modifiers: u4 = 0,
        clickCount: i32 = 0,
        deltaX: f64 = 0,
        deltaY: f64 = 0,
        // Many optional parameters are not implemented yet, see documentation url.

        const Type = enum {
            mousePressed,
            mouseReleased,
            mouseMoved,
            mouseWheel,
        };

        // https://chromedevtools.github.io/devtools-protocol/tot/Input/#type-MouseButton
        const Button = enum {
            none,
            left,
            middle,
            right,
            back,
            forward,
        };
    })) orelse return error.InvalidParams;

    try cmd.sendResult(null, .{});

    const bc = cmd.browser_context orelse return;
    const frame = bc.mainFrame() orelse return;

    // Map the CDP button name to the DOM MouseEvent.button value.
    // https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/button
    const button: i32 = switch (params.button) {
        .none, .left => dom_button.main,
        .middle => dom_button.auxiliary,
        .right => dom_button.secondary,
        .back => dom_button.fourth,
        .forward => dom_button.fifth,
    };
    const button_mask: u16 = switch (params.button) {
        .none, .left => 1,
        .right => 2,
        .middle => 4,
        .back => 8,
        .forward => 16,
    };
    const modifiers: Frame.user_input.MouseModifiers = .{
        .alt = params.modifiers & 1 == 1,
        .control = params.modifiers & 2 == 2,
        .meta = params.modifiers & 4 == 4,
        .shift = params.modifiers & 8 == 8,
    };
    const state = currentMouseState(cmd, frame);

    switch (params.type) {
        .mousePressed => {
            const buttons = params.buttons orelse (state.buttons | button_mask);
            state.down[@intCast(button)] = try Frame.user_input.triggerMousePressWithState(
                frame,
                params.x,
                params.y,
                button,
                buttons,
                params.clickCount,
                modifiers,
            );
            state.buttons = buttons;
        },
        .mouseReleased => {
            const buttons = params.buttons orelse (state.buttons & ~button_mask);
            const down = state.down[@intCast(button)];
            state.down[@intCast(button)] = null;
            state.buttons = buttons;
            try Frame.user_input.triggerMouseReleaseWithState(
                frame,
                params.x,
                params.y,
                button,
                buttons,
                params.clickCount,
                modifiers,
                down,
            );
        },
        .mouseMoved => {
            const buttons = params.buttons orelse state.buttons;
            state.buttons = buttons;
            try Frame.user_input.triggerMouseMoveWithOptions(frame, params.x, params.y, buttons, modifiers);
        },
        .mouseWheel => {
            const buttons = params.buttons orelse state.buttons;
            state.buttons = buttons;
            try Frame.user_input.triggerMouseWheelWithOptions(frame, params.x, params.y, params.deltaX, params.deltaY, buttons, modifiers);
        },
    }
    // result already sent
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-insertText
fn insertText(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        text: []const u8, // The text to insert
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return;
    const frame = bc.mainFrame() orelse return;

    try Frame.user_input.insertText(frame, params.text);

    try cmd.sendResult(null, .{});
}

const lp = @import("lightpanda");
const testing = @import("../testing.zig");

test "cdp.input: dispatchMouseEvent mouseMoved fires hover events" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // Register listeners for the full enter sequence on #hoverTarget, then read
    // its (faux-layout) position so we can target it precisely.
    _ = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('mousemove', () => { window.moved = true; });
        \\t.addEventListener('mouseenter', () => { window.entered = true; });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseMoved", .x = rect_x, .y = rect_y },
    });

    const result = try ls.local.compileAndRun("window.hovered === true && window.entered === true && window.moved === true", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchMouseEvent mouseReleased fires mouseup" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\document.getElementById('hoverTarget')
        \\  .addEventListener('mouseup', () => { window.released = true; });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y },
    });

    const result = try ls.local.compileAndRun("window.released === true", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchMouseEvent mouseWheel fires wheel event" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\document.getElementById('scrollbox')
        \\  .addEventListener('wheel', (e) => { window.wheelDeltaY = e.deltaY; });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('scrollbox').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('scrollbox').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = rect_x, .y = rect_y, .deltaY = 40 },
    });

    const result = try ls.local.compileAndRun("window.wheelDeltaY === 40", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchMouseEvent preserves state and event metadata" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\const hoverTarget = document.getElementById('hoverTarget');
        \\const btn = document.getElementById('btn');
        \\window.mouseLog = [];
        \\for (const target of [hoverTarget, btn]) {
        \\  for (const type of ['mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu']) {
        \\    target.addEventListener(type, event => mouseLog.push({
        \\      type, target: event.target.id, button: event.button,
        \\      buttons: event.buttons, x: event.clientX, y: event.clientY,
        \\      alt: event.altKey, ctrl: event.ctrlKey,
        \\      meta: event.metaKey, shift: event.shiftKey
        \\    }));
        \\  }
        \\}
    , null);

    const target_x = try (try ls.local.compileAndRun("hoverTarget.getBoundingClientRect().x", null)).toF64();
    const target_y = try (try ls.local.compileAndRun("hoverTarget.getBoundingClientRect().y", null)).toF64();
    const button_x = try (try ls.local.compileAndRun("btn.getBoundingClientRect().x", null)).toF64();
    const button_y = try (try ls.local.compileAndRun("btn.getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = target_x, .y = target_y, .button = "right", .buttons = 2 },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = target_x, .y = target_y, .button = "right", .buttons = 0 },
    });

    // Releasing over a different target still fires mouseup, but not click.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = target_x, .y = target_y, .button = "left" },
    });
    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = button_x, .y = button_y, .button = "left" },
    });

    // A valid pair carries CDP metadata, focuses normally, and can double-click.
    try ctx.processMessage(.{
        .id = 5,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = button_x, .y = button_y, .button = "left", .modifiers = 9, .clickCount = 2 },
    });
    try ctx.processMessage(.{
        .id = 6,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = button_x, .y = button_y, .button = "left", .modifiers = 9, .clickCount = 2 },
    });

    const result = try ls.local.compileAndRun(
        \\mouseLog.filter(e => e.type === 'contextmenu').length === 1 &&
        \\mouseLog.filter(e => e.type === 'click').length === 1 &&
        \\mouseLog.filter(e => e.type === 'dblclick').length === 1 &&
        \\mouseLog.some(e => e.type === 'mouseup' && e.target === 'btn') &&
        \\mouseLog.some(e => e.type === 'mousedown' && e.target === 'btn' &&
        \\  e.button === 0 && e.buttons === 1 && e.x === btn.getBoundingClientRect().x &&
        \\  e.y === btn.getBoundingClientRect().y && e.alt && !e.ctrl && !e.meta && e.shift) &&
        \\mouseLog.some(e => e.type === 'mouseup' && e.target === 'btn' &&
        \\  e.button === 0 && e.buttons === 0 && e.alt && e.shift) &&
        \\document.activeElement === btn && window.clicked === true
    , null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchKeyEvent rawKeyDown dispatches keydown without text" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\document.body.innerHTML =
        \\  '<form id="form"><input id="target"></form><input id="next">';
        \\const target = document.getElementById('target');
        \\window.keyEvents = [];
        \\window.inputEvents = 0;
        \\target.addEventListener('keydown', record);
        \\target.addEventListener('keypress', record);
        \\target.addEventListener('keyup', record);
        \\target.addEventListener('input', () => { window.inputEvents++; });
        \\function record(e) {
        \\  window.keyEvents.push({
        \\    type: e.type, key: e.key, code: e.code,
        \\    repeat: e.repeat, location: e.location,
        \\    alt: e.altKey, ctrl: e.ctrlKey,
        \\    meta: e.metaKey, shift: e.shiftKey
        \\  });
        \\}
        \\target.focus();
    , null);

    // Automation clients send rawKeyDown for keys without generated text.
    // It must still surface as a DOM keydown with the supplied metadata.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchKeyEvent",
        .params = .{
            .type = "rawKeyDown",
            .key = "a",
            .code = "KeyA",
            .modifiers = 9,
            .autoRepeat = true,
            .location = 2,
        },
    });
    try testing.expect((try ls.local.compileAndRun(
        \\target.value === '' &&
        \\window.inputEvents === 0 &&
        \\window.keyEvents.length === 1 &&
        \\window.keyEvents[0].type === 'keydown' &&
        \\window.keyEvents[0].key === 'a' &&
        \\window.keyEvents[0].code === 'KeyA' &&
        \\window.keyEvents[0].repeat === true &&
        \\window.keyEvents[0].location === 2 &&
        \\window.keyEvents[0].alt === true &&
        \\window.keyEvents[0].ctrl === false &&
        \\window.keyEvents[0].meta === false &&
        \\window.keyEvents[0].shift === true
    , null)).isTrue());

    // Existing keyDown, char and keyUp behavior stays unchanged: one text
    // insertion from keyDown, followed by keypress and keyup DOM events.
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "a", .code = "KeyA" },
    });
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "char", .key = "a", .code = "KeyA" },
    });
    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyUp", .key = "a", .code = "KeyA" },
    });
    try testing.expect((try ls.local.compileAndRun(
        \\target.value === 'a' &&
        \\window.inputEvents === 1 &&
        \\window.keyEvents.map(e => e.type).join(',') ===
        \\  'keydown,keydown,keypress,keyup'
    , null)).isTrue());

    // rawKeyDown keeps non-text defaults. Enter submits once and Tab advances
    // focus, while neither inserts text.
    _ = try ls.local.compileAndRun(
        \\window.submitCount = 0;
        \\document.getElementById('form').addEventListener('submit', e => {
        \\  e.preventDefault();
        \\  window.submitCount++;
        \\});
        \\target.value = '';
        \\target.focus();
    , null);
    try ctx.processMessage(.{
        .id = 5,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "rawKeyDown", .key = "Enter", .code = "Enter" },
    });
    try testing.expect((try ls.local.compileAndRun(
        "window.submitCount === 1 && target.value === ''",
        null,
    )).isTrue());

    try ctx.processMessage(.{
        .id = 6,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "rawKeyDown", .key = "Tab", .code = "Tab" },
    });
    try testing.expect((try ls.local.compileAndRun(
        "document.activeElement.id === 'next' && target.value === ''",
        null,
    )).isTrue());

    // Chrome's normal text sequence carries insertion data on the char event.
    _ = try ls.local.compileAndRun(
        \\target.value = '';
        \\window.keyEvents = [];
        \\window.inputEvents = 0;
        \\target.focus();
    , null);
    try ctx.processMessage(.{
        .id = 7,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "rawKeyDown", .key = "x", .code = "KeyX" },
    });
    try ctx.processMessage(.{
        .id = 8,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "char", .text = "x" },
    });
    try ctx.processMessage(.{
        .id = 9,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyUp", .key = "x", .code = "KeyX" },
    });
    try testing.expect((try ls.local.compileAndRun(
        \\target.value === 'x' && window.inputEvents === 1 &&
        \\window.keyEvents.map(e => e.type).join(',') === 'keydown,keypress,keyup' &&
        \\window.keyEvents[1].key === 'x'
    , null)).isTrue());
}

test "cdp.input: dispatchKeyEvent Tab runs sequential focus navigation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // Three controls whose tabindex order (1, 2, 3) differs from document
    // order (2, 1, 3): focus order must follow tabindex, not the tree.
    _ = try ls.local.compileAndRun(
        \\document.body.innerHTML =
        \\  '<input id="i2" tabindex="2">' +
        \\  '<button id="b1" tabindex="1">b</button>' +
        \\  '<select id="s3" tabindex="3"></select>';
    , null);

    // Nothing focused yet → activeElement is <body>.
    try testing.expect((try ls.local.compileAndRun("document.activeElement === document.body", null)).isTrue());

    // First Tab → lowest positive tabindex (#b1), regardless of document order.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "Tab", .code = "Tab" },
    });
    try testing.expect((try ls.local.compileAndRun("document.activeElement.id === 'b1'", null)).isTrue());

    // Second Tab → next in tabindex order (#i2).
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "Tab", .code = "Tab" },
    });
    try testing.expect((try ls.local.compileAndRun("document.activeElement.id === 'i2'", null)).isTrue());

    // Shift+Tab (modifiers bit 8) walks backward → back to #b1.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "Tab", .code = "Tab", .modifiers = 8 },
    });
    try testing.expect((try ls.local.compileAndRun("document.activeElement.id === 'b1'", null)).isTrue());
}
