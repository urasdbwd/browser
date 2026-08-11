// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");
const Frame = @import("Frame.zig");
const Node = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const Slot = @import("webapi/element/html/Slot.zig");
const IFrame = @import("webapi/element/html/IFrame.zig");
const Link = @import("webapi/element/html/Link.zig");
const Canvas = @import("webapi/element/html/Canvas.zig");

const Input = Element.Html.Input;
const Option = Element.Html.Option;
const Select = Element.Html.Select;
const TextArea = Element.Html.TextArea;

pub const MAX_LIVE_TARGETS = std.math.maxInt(u16);
const LIVE_INDETERMINATE_ATTR = "data-lightpanda-live-indeterminate";
const LIVE_SELECTED_NONE_ATTR = "data-lightpanda-live-selected-none";
const LIVE_FRAME_ATTR = "data-lightpanda-live-frame";
const LIVE_TARGET_ATTR_PREFIX = "data-lp-t-";
const LIVE_TARGET_KEY_ATTR_PREFIX = "data-lp-k-";
pub const LIVE_CANVAS_ATTR = "data-lp-canvas";
// CSP3 has no generic anchor-navigation directive. Render clients must also
// sandbox the snapshot frame and cancel captured link navigation.
const RENDER_CSP_META =
    "<meta http-equiv=\"Content-Security-Policy\" content=\"" ++
    "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; " ++
    "img-src data: blob:; media-src data: blob:; font-src data: blob:; " ++
    "connect-src 'none'; frame-src 'self' about:; child-src 'self' about:; " ++
    "worker-src 'none'; " ++
    "object-src 'none'; form-action 'none'\">";
/// Bot-challenge widgets are the one cross-origin frame worth allowing: the
/// snapshot ships the vendor's iframe element, but `frame-src 'self'` blocks it
/// in the viewer's browser, so the operator sees an empty box instead of a
/// checkbox they could click. Scoped to these four origins rather than `https:`
/// so enabling direct resources does not turn every third-party frame on the
/// page loose. Only reachable with direct resources on, which already accepts
/// that the viewer's browser talks to third-party origins.
const RENDER_CSP_CAPTCHA_FRAMES =
    "https://challenges.cloudflare.com https://*.hcaptcha.com " ++
    "https://www.google.com https://www.recaptcha.net";
const RENDER_CSP_DIRECT_RESOURCES_META =
    "<meta http-equiv=\"Content-Security-Policy\" content=\"" ++
    "default-src 'none'; script-src 'none'; " ++
    "style-src 'unsafe-inline' data: blob: http: https:; " ++
    "img-src data: blob: http: https:; media-src data: blob: http: https:; " ++
    "font-src data: blob: http: https:; " ++
    "connect-src 'none'; " ++
    "frame-src 'self' about: " ++ RENDER_CSP_CAPTCHA_FRAMES ++ "; " ++
    "child-src 'self' about: " ++ RENDER_CSP_CAPTCHA_FRAMES ++ "; " ++
    "worker-src 'none'; " ++
    "object-src 'none'; form-action 'none'\">";
const RENDER_REFERRER_META = "<meta name=\"referrer\" content=\"no-referrer\">";

pub const Opts = struct {
    with_base: bool = false,
    with_frames: bool = false,
    strip: Opts.Strip = .{},
    shadow: Opts.Shadow = .rendered,
    /// Reflect mutable form-control properties into a transport snapshot.
    /// Password values are always omitted.
    live_form_state: bool = false,
    /// Inject a restrictive policy for inert client-side render snapshots.
    /// This also strips source CSP and refresh meta elements.
    with_render_csp: bool = false,
    /// Let an explicitly opted-in client fetch visual resources directly.
    direct_render_resources: bool = false,
    /// Assign opaque, snapshot-local IDs to the exact elements emitted by the
    /// rendered shadow/slot traversal.
    live_targets: ?LiveTargets = null,

    pub const Strip = packed struct(u5) {
        js: bool = false,
        ui: bool = false,
        css: bool = false,
        invisible: bool = false,
        meta: bool = false,
    };

    pub const Shadow = enum {
        // Skip shadow DOM entirely (innerHTML/outerHTML)
        skip,

        // Dump everything (like "view source")
        complete,

        // Resolve slot elements (like what actually gets rendered)
        rendered,
    };
};

pub const LiveTargets = struct {
    allocator: std.mem.Allocator,
    elements: *std.ArrayList(*Element),
    version: *const [16]u8,
    key_secret: u64,
    page_incarnation: u64,
};

pub fn root(doc: *Node.Document, opts: Opts, writer: *std.Io.Writer, frame: *Frame) !void {
    var missing_head = false;
    if (doc.is(Node.Document.HTMLDocument)) |html_doc| {
        missing_head = html_doc.getHead() == null;
        blk: {
            // Ideally we just render the doctype which is part of the document
            if (doc.asNode().firstChild()) |first| {
                if (first._type == .document_type) {
                    break :blk;
                }
            }
            // But if the doc has no child, or the first child isn't a doctype
            // well force it.
            try writer.writeAll("<!DOCTYPE html>");
        }
    }

    var state: RootState = .{
        .inject_base = opts.with_base,
        .inject_render_csp = opts.with_render_csp,
        .direct_render_resources = opts.direct_render_resources,
        .synthesize_head = missing_head and (opts.with_base or opts.with_render_csp),
    };
    return _deep(doc.asNode(), opts, false, writer, frame, &state);
}

pub fn deep(node: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame) error{WriteFailed}!void {
    return _deep(node, opts, false, writer, frame, null) catch error.WriteFailed;
}

const RootState = struct {
    inject_base: bool,
    inject_render_csp: bool,
    direct_render_resources: bool,
    synthesize_head: bool,
};

fn _deep(
    node: *Node,
    opts: Opts,
    comptime force_slot: bool,
    writer: *std.Io.Writer,
    frame: *Frame,
    root_state: ?*RootState,
) error{ WriteFailed, OutOfMemory }!void {
    switch (node._type) {
        .cdata => {
            const cd = node.subtype(Node.CData);
            if (node.is(Node.CData.Comment)) |_| {
                try writer.writeAll("<!--");
                try writer.writeAll(cd.getData().str());
                try writer.writeAll("-->");
            } else if (node.is(Node.CData.ProcessingInstruction)) |pi| {
                try writer.writeAll("<?");
                try writer.writeAll(pi._target);
                try writer.writeAll(" ");
                try writer.writeAll(cd.getData().str());
                try writer.writeAll("?>");
            } else {
                if (shouldEscapeText(node._parent)) {
                    try writeEscapedText(cd.getData().str(), writer);
                } else {
                    try writer.writeAll(cd.getData().str());
                }
            }
        },
        .element => {
            const el = node.subtype(Node.Element);
            if (shouldStripElement(el, opts, frame)) {
                return;
            }

            if (opts.with_render_csp) {
                if (el.is(Link)) |link| {
                    if (link._sheet) |sheet| {
                        try writer.writeAll("<style>");
                        try sheet.writeCssRules(writer, frame);
                        try writer.writeAll("</style>");
                        return;
                    }
                }
            }

            // When opts.shadow == .rendered, we normally skip any element with
            // a slot attribute. Only the "active" element will get rendered into
            // the <slot name="X">. However, the `deep` function is itself used
            // to render that "active" content, so when we're trying to render
            // it, we don't want to skip it.
            if ((comptime force_slot == false) and opts.shadow == .rendered) {
                if (el.getAttributeSafe(comptime .wrap("slot"))) |_| {
                    // Skip - will be rendered by the Slot if it's the active container
                    return;
                }
            }

            if (opts.live_form_state or
                opts.live_targets != null or
                (opts.with_frames and opts.with_render_csp and el.is(IFrame) != null))
            {
                try writeSnapshotStartTag(el, opts, writer, frame);
            } else {
                try el.format(writer);
            }
            if (root_state) |state| {
                const tag_name = el.getTagNameDump();
                if (state.synthesize_head and std.mem.eql(u8, tag_name, "html")) {
                    try writer.writeAll("<head>");
                    try writeRootHead(state, writer, frame);
                    try writer.writeAll("</head>");
                    state.synthesize_head = false;
                } else if (std.mem.eql(u8, tag_name, "head")) {
                    try writeRootHead(state, writer, frame);
                }
            }

            if (opts.shadow == .rendered) {
                if (el.is(Slot)) |slot| {
                    try dumpSlotContent(slot, opts, writer, frame, root_state);
                    return writer.writeAll("</slot>");
                }
            }
            if (opts.shadow != .skip) {
                if (frame._element_shadow_roots.get(el)) |shadow| {
                    try _children(shadow.asNode(), opts, writer, frame, root_state);
                    // In rendered mode, light DOM is only shown through slots, not directly
                    if (opts.shadow == .rendered) {
                        // Skip rendering light DOM children
                        if (!isVoidElement(el)) {
                            try writer.writeAll("</");
                            try writer.writeAll(el.getTagNameDump());
                            try writer.writeByte('>');
                        }
                        return;
                    }
                }
            }

            if (opts.with_frames and !opts.with_render_csp and el.is(IFrame) != null) {
                const iframe = el.as(IFrame);
                if (iframe.getContentDocument()) |doc| {
                    // A frame's document should always ahave a frame, but
                    // I'm not willing to crash a release build on that assertion.
                    if (comptime lp.IS_DEBUG) {
                        std.debug.assert(doc._frame != null);
                    }
                    if (doc._frame) |f| {
                        try writer.writeByte('\n');
                        try root(doc, opts, writer, f);
                        try writer.writeByte('\n');
                    }
                }
            } else {
                if (opts.with_render_csp) {
                    if (el.is(Element.Html.Style)) |style| {
                        if (style._sheet) |sheet| {
                            try sheet.writeCssRules(writer, frame);
                        } else {
                            try _children(node, opts, writer, frame, root_state);
                        }
                    } else if (opts.live_form_state) {
                        if (el.is(TextArea)) |textarea| {
                            const value = textarea.getValue();
                            // HTML parsing ignores one leading LF in a textarea.
                            if (std.mem.startsWith(u8, value, "\n")) try writer.writeByte('\n');
                            try writeEscapedText(value, writer);
                        } else {
                            try _children(node, opts, writer, frame, root_state);
                        }
                    } else {
                        try _children(node, opts, writer, frame, root_state);
                    }
                } else if (opts.live_form_state) {
                    if (el.is(TextArea)) |textarea| {
                        const value = textarea.getValue();
                        // HTML parsing ignores one leading LF in a textarea.
                        if (std.mem.startsWith(u8, value, "\n")) try writer.writeByte('\n');
                        try writeEscapedText(value, writer);
                    } else {
                        try _children(node, opts, writer, frame, root_state);
                    }
                } else {
                    try _children(node, opts, writer, frame, root_state);
                }
            }

            if (!isVoidElement(el)) {
                try writer.writeAll("</");
                try writer.writeAll(el.getTagNameDump());
                try writer.writeByte('>');
            }
        },
        .document => try _children(node, opts, writer, frame, root_state),
        .document_type => {
            const dt = node.subtype(Node.DocumentType);
            try writer.writeAll("<!DOCTYPE ");
            try writer.writeAll(dt.getName());

            const public_id = dt.getPublicId();
            const system_id = dt.getSystemId();
            if (public_id.len != 0 and system_id.len != 0) {
                try writer.writeAll(" PUBLIC \"");
                try writeEscapedText(public_id, writer);
                try writer.writeAll("\" \"");
                try writeEscapedText(system_id, writer);
                try writer.writeByte('"');
            } else if (public_id.len != 0) {
                try writer.writeAll(" PUBLIC \"");
                try writeEscapedText(public_id, writer);
                try writer.writeByte('"');
            } else if (system_id.len != 0) {
                try writer.writeAll(" SYSTEM \"");
                try writeEscapedText(system_id, writer);
                try writer.writeByte('"');
            }
            try writer.writeAll(">\n");
        },
        .document_fragment => try _children(node, opts, writer, frame, root_state),
        .attribute => {
            // Not called normally, but can be called via XMLSerializer.serializeToString
            // in which case it should return an empty string
            try writer.writeAll("");
        },
    }
}

pub fn children(parent: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame) !void {
    return _children(parent, opts, writer, frame, null);
}

fn _children(parent: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame, root_state: ?*RootState) !void {
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        try _deep(child, opts, false, writer, frame, root_state);
    }
}

pub fn toJSON(node: *Node, writer: *std.json.Stringify) !void {
    try writer.beginObject();

    try writer.objectField("type");
    switch (node._type) {
        .cdata => {
            try writer.write("cdata");
        },
        .document => {
            try writer.write("document");
        },
        .document_type => {
            try writer.write("document_type");
        },
        .element => {
            const el = node.subtype(Node.Element);
            try writer.write("element");
            try writer.objectField("tag");
            try writer.write(el.tagName());

            try writer.objectField("attributes");
            try writer.beginObject();
            var it = el.attributeIterator();
            while (it.next()) |attr| {
                try writer.objectField(attr.name);
                try writer.write(attr.value);
            }
            try writer.endObject();
        },
    }

    try writer.objectField("children");
    try writer.beginArray();
    var it = node.childrenIterator();
    while (it.next()) |child| {
        try toJSON(child, writer);
    }
    try writer.endArray();
    try writer.endObject();
}

fn dumpSlotContent(slot: *Slot, opts: Opts, writer: *std.Io.Writer, frame: *Frame, root_state: ?*RootState) !void {
    const assigned = slot.assignedNodes(null, frame) catch return;

    if (assigned.len > 0) {
        for (assigned) |assigned_node| {
            try _deep(assigned_node, opts, true, writer, frame, root_state);
        }
    } else {
        try _children(slot.asNode(), opts, writer, frame, root_state);
    }
}

fn isVoidElement(el: *const Node.Element) bool {
    return switch (el.typed()) {
        .html => |html| switch (html._type) {
            .base, .br, .hr, .img, .input, .link, .meta => true,
            else => false,
        },
        .svg => false,
    };
}

fn writeSnapshotStartTag(
    el: *Element,
    opts: Opts,
    writer: *std.Io.Writer,
    frame: *Frame,
) !void {
    const input = el.is(Input);
    const option = el.is(Option);
    const select = el.is(Select);
    const iframe = el.is(IFrame);
    const transport_frame = opts.with_frames and opts.with_render_csp and iframe != null;
    const child_frame: ?*Frame = if (transport_frame) child: {
        const doc = iframe.?.getContentDocument() orelse break :child null;
        const owner = doc._frame orelse break :child null;
        if (owner._page != frame._page) break :child null;
        break :child owner;
    } else null;
    const input_type = if (input) |value| value.getType() else "";
    const checkable = std.mem.eql(u8, input_type, "checkbox") or
        std.mem.eql(u8, input_type, "radio");
    const password = std.mem.eql(u8, input_type, "password");
    const file = std.mem.eql(u8, input_type, "file");
    const target_id: ?u16 = if (opts.live_targets) |targets| target: {
        if (targets.elements.items.len >= MAX_LIVE_TARGETS) return error.WriteFailed;
        try targets.elements.append(targets.allocator, el);
        break :target @intCast(targets.elements.items.len);
    } else null;

    try writer.writeByte('<');
    try writer.writeAll(el.getTagNameDump());
    for (el._attributes.entries()) |*attr| {
        const name = attr.name();
        if (opts.live_form_state) {
            if (std.mem.eql(u8, name, LIVE_INDETERMINATE_ATTR) or
                std.mem.eql(u8, name, LIVE_SELECTED_NONE_ATTR)) continue;
            if (input != null and std.mem.eql(u8, name, "checked") and checkable) continue;
            if (input != null and std.mem.eql(u8, name, "value")) continue;
            if (option != null and std.mem.eql(u8, name, "selected")) continue;
        }
        if (opts.live_targets != null and isLiveTargetAttribute(name)) continue;
        if (transport_frame and
            (std.ascii.eqlIgnoreCase(name, "src") or
                std.ascii.eqlIgnoreCase(name, "srcdoc") or
                std.ascii.eqlIgnoreCase(name, "sandbox") or
                std.ascii.eqlIgnoreCase(name, LIVE_FRAME_ATTR)))
        {
            continue;
        }
        try writer.print(" {f}", .{attr});
    }

    if (opts.live_form_state) {
        if (input) |value| {
            if (checkable) {
                if (value.getChecked()) try writer.writeAll(" checked");
            }
            if (!password and !file) {
                try writer.writeAll(" value=\"");
                try writeEscapedAttributeValue(value.getValue(), writer);
                try writer.writeByte('"');
            }
            if (value.getIndeterminate()) {
                try writer.writeAll(" " ++ LIVE_INDETERMINATE_ATTR);
            }
        }
        if (option) |value| {
            if (value.getSelected()) try writer.writeAll(" selected");
        }
        if (select) |value| {
            if (value.getSelectedIndex() == -1) {
                try writer.writeAll(" " ++ LIVE_SELECTED_NONE_ATTR);
            }
        }
    }
    if (transport_frame) {
        try writer.writeAll(" sandbox=\"allow-same-origin\"");
    }
    if (target_id) |id| {
        const targets = opts.live_targets.?;
        const key = liveTargetKey(el, targets.key_secret, targets.page_incarnation);
        const key_hex = hexU64(key);
        try writer.writeByte(' ');
        try writer.writeAll(LIVE_TARGET_ATTR_PREFIX);
        try writer.writeAll(targets.version);
        try writer.print("=\"{d}\"", .{id});
        try writer.writeByte(' ');
        try writer.writeAll(LIVE_TARGET_KEY_ATTR_PREFIX);
        try writer.writeAll(targets.version);
        try writer.writeAll("=\"");
        try writer.writeAll(&key_hex);
        try writer.writeByte('"');
    }
    if (opts.live_targets != null) {
        if (el.is(Canvas)) |canvas| try writeCanvasOps(canvas, writer);
    }
    if (child_frame) |child| {
        try writer.writeByte(' ');
        try writer.writeAll(LIVE_FRAME_ATTR);
        try writer.writeAll(" srcdoc=\"");
        var escaped: EscapedAttributeWriter = .init(writer);
        try root(child.document, opts, &escaped.writer, child);
        try writer.writeByte('"');
    }
    try writer.writeByte('>');
}

/// Canvas pixels never leave the server — Lightpanda has no rasterizer. The 2D
/// op log rides along on the element instead and the client replays it onto a
/// real canvas. Only ops recorded since the previous snapshot are emitted, so a
/// long-running animation costs a constant number of bytes per frame rather than
/// resending its whole history. A leading '!' marks a log that overflowed and is
/// therefore missing ops.
fn writeCanvasOps(canvas: *Canvas, writer: *std.Io.Writer) !void {
    const ctx = canvas.context2d() orelse return;
    const ops = ctx.pendingOps();
    if (ops.len == 0) return;

    try writer.writeAll(" " ++ LIVE_CANVAS_ATTR ++ "=\"");
    if (ctx.opsDropped()) try writer.writeByte('!');
    try writeEscapedAttributeValue(ops, writer);
    try writer.writeByte('"');
    ctx.markOpsSent();
}

const EscapedAttributeWriter = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &vtable },

    fn init(out: *std.Io.Writer) EscapedAttributeWriter {
        return .{ .out = out };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *EscapedAttributeWriter = @alignCast(@fieldParentPtr("writer", writer));
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.write(bytes);
            written += bytes.len;
        }
        const repeated = data[data.len - 1];
        for (0..splat) |_| {
            try self.write(repeated);
            written += repeated.len;
        }
        return written;
    }

    fn write(self: *EscapedAttributeWriter, bytes: []const u8) std.Io.Writer.Error!void {
        writeEscapedAttributeValue(bytes, self.out) catch return error.WriteFailed;
    }
};

fn isLiveTargetAttribute(name: []const u8) bool {
    const prefix_len = if (std.ascii.startsWithIgnoreCase(name, LIVE_TARGET_ATTR_PREFIX))
        LIVE_TARGET_ATTR_PREFIX.len
    else if (std.ascii.startsWithIgnoreCase(name, LIVE_TARGET_KEY_ATTR_PREFIX))
        LIVE_TARGET_KEY_ATTR_PREFIX.len
    else
        return false;
    if (name.len != prefix_len + 16) return false;
    for (name[prefix_len..]) |byte| {
        if (!std.ascii.isDigit(byte) and
            !(byte >= 'a' and byte <= 'f') and
            !(byte >= 'A' and byte <= 'F'))
        {
            return false;
        }
    }
    return true;
}

fn liveTargetKey(el: *Element, secret: u64, page_incarnation: u64) u64 {
    const input = [2]u64{ @intFromPtr(el), page_incarnation };
    return std.hash.Wyhash.hash(secret, std.mem.asBytes(&input));
}

fn hexU64(value: u64) [16]u8 {
    const big_endian = std.mem.nativeToBig(u64, value);
    return std.fmt.bytesToHex(std.mem.asBytes(&big_endian), .lower);
}

fn shouldStripElement(el: *Node.Element, opts: Opts, frame: *Frame) bool {
    // Fast path: with no strip flags set (every innerHTML/outerHTML call)
    if (@as(u5, @bitCast(opts.strip)) == 0 and !opts.with_render_csp) {
        return false;
    }

    const tag_name = el.getTagNameDump();
    if (opts.with_render_csp and std.ascii.eqlIgnoreCase(tag_name, "frame")) return true;

    if (opts.strip.js) {
        if (std.mem.eql(u8, tag_name, "script")) return true;
        if (std.mem.eql(u8, tag_name, "noscript")) return true;

        if (std.mem.eql(u8, tag_name, "link")) {
            if (el.getAttributeSafe(comptime .wrap("as"))) |as| {
                if (std.ascii.eqlIgnoreCase(as, "script")) return true;
            }
            if (el.getAttributeSafe(comptime .wrap("rel"))) |rel| {
                if (hasAsciiToken(rel, "modulepreload")) return true;
                if (hasAsciiToken(rel, "preload")) {
                    if (el.getAttributeSafe(comptime .wrap("as"))) |as| {
                        if (std.ascii.eqlIgnoreCase(as, "script")) return true;
                    }
                }
            }
        }
    }

    if ((opts.strip.meta or opts.with_render_csp) and std.mem.eql(u8, tag_name, "meta")) {
        if (el.getAttributeSafe(comptime .wrap("http-equiv"))) |raw| {
            if (isUnsafeHttpEquiv(raw)) return true;
        }
        if (opts.with_render_csp) {
            if (el.getAttributeSafe(comptime .wrap("name"))) |raw| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, &std.ascii.whitespace), "referrer")) {
                    return true;
                }
            }
        }
    }

    if (opts.strip.css or opts.strip.ui) {
        if (std.mem.eql(u8, tag_name, "style")) return true;

        if (std.mem.eql(u8, tag_name, "link")) {
            if (el.getAttributeSafe(comptime .wrap("rel"))) |rel| {
                if (std.mem.eql(u8, rel, "stylesheet")) return true;
            }
        }
    }

    if (opts.strip.ui) {
        if (std.mem.eql(u8, tag_name, "img")) return true;
        if (std.mem.eql(u8, tag_name, "picture")) return true;
        if (std.mem.eql(u8, tag_name, "video")) return true;
        if (std.mem.eql(u8, tag_name, "audio")) return true;
        if (std.mem.eql(u8, tag_name, "svg")) return true;
        if (std.mem.eql(u8, tag_name, "canvas")) return true;
        if (std.mem.eql(u8, tag_name, "iframe")) return true;
    }

    if (opts.strip.invisible and frame._style_manager.hasAuthorDisplayNone(el)) {
        return true;
    }

    return false;
}

fn writeRootHead(state: *RootState, writer: *std.Io.Writer, frame: *Frame) !void {
    if (state.inject_render_csp) {
        try writer.writeAll(if (state.direct_render_resources)
            RENDER_CSP_DIRECT_RESOURCES_META
        else
            RENDER_CSP_META);
        try writer.writeAll(RENDER_REFERRER_META);
        state.inject_render_csp = false;
    }
    if (state.inject_base) {
        try writer.writeAll("<base href=\"");
        try writeEscapedAttributeValue(frame.base(), writer);
        try writer.writeAll("\">");
        state.inject_base = false;
    }
}

fn hasAsciiToken(value: []const u8, wanted: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, value, &std.ascii.whitespace);
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, wanted)) return true;
    }
    return false;
}

fn isUnsafeHttpEquiv(raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(value, "refresh") or
        std.ascii.startsWithIgnoreCase(value, "content-security-policy");
}

fn shouldEscapeText(node_: ?*Node) bool {
    // Raw text elements serialize their text content literally rather than
    // HTML-escaping it
    const node = node_ orelse return true;
    const element = node.is(Node.Element) orelse return true;
    const html_element = node.is(Node.Element.Html) orelse return true;

    switch (html_element._type) {
        .style, .script, .iframe => return false,
        else => {
            const tag = element.getTagNameLower();
            inline for (.{ "xmp", "noembed", "noframes", "plaintext", "noscript" }) |raw_text_tag| {
                if (std.mem.eql(u8, tag, raw_text_tag)) {
                    return false;
                }
            }
        },
    }
    return true;
}
fn writeEscapedText(text: []const u8, writer: *std.Io.Writer) !void {
    // Fast path: if no special characters, write directly
    const first_special = std.mem.indexOfAnyPos(u8, text, 0, &.{ '&', '<', '>', 194 }) orelse {
        return writer.writeAll(text);
    };

    try writer.writeAll(text[0..first_special]);
    var remaining = try writeEscapedByte(text, first_special, writer);

    while (std.mem.indexOfAnyPos(u8, remaining, 0, &.{ '&', '<', '>', 194 })) |offset| {
        try writer.writeAll(remaining[0..offset]);
        remaining = try writeEscapedByte(remaining, offset, writer);
    }

    if (remaining.len > 0) {
        try writer.writeAll(remaining);
    }
}

fn writeEscapedAttributeValue(value: []const u8, writer: *std.Io.Writer) !void {
    var remaining = value;
    while (std.mem.indexOfAny(u8, remaining, "&\"<>")) |offset| {
        try writer.writeAll(remaining[0..offset]);
        try writer.writeAll(switch (remaining[offset]) {
            '&' => "&amp;",
            '"' => "&quot;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => unreachable,
        });
        remaining = remaining[offset + 1 ..];
    }
    try writer.writeAll(remaining);
}

fn writeEscapedByte(input: []const u8, index: usize, writer: *std.Io.Writer) ![]const u8 {
    switch (input[index]) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        194 => {
            // non breaking space
            if (input.len > index + 1 and input[index + 1] == 160) {
                try writer.writeAll("&nbsp;");
                return input[index + 2 ..];
            }
            try writer.writeByte(194);
        },
        else => unreachable,
    }
    return input[index + 1 ..];
}

const testing = @import("../testing.zig");

fn expectDump(opts: Opts, expected: []const u8) !void {
    var page = try testing.pageTest("dump.html", .{});
    defer page.close();

    const frame = page.frame().?;

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.window._document, opts, &aw.writer, frame);
    try testing.expectString(expected, aw.written());
}

test "dump: default dumps the whole document" {
    try expectDump(.{},
        \\<!DOCTYPE html>
        \\<html><head><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: with_base injects a <base> element" {
    try expectDump(.{ .with_base = true },
        \\<!DOCTYPE html>
        \\<html><head><base href="http://127.0.0.1:9582/src/browser/tests/dump.html"><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: with_base does not mutate the document" {
    var page = try testing.pageTest("dump.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var first: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{ .with_base = true }, &first.writer, frame);

    var second: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{}, &second.writer, frame);
    try testing.expect(std.mem.indexOf(u8, second.written(), "<base") == null);
}

test "dump: strip.js removes script and noscript" {
    try expectDump(.{ .strip = .{ .js = true } },
        \\<!DOCTYPE html>
        \\<html><head><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><p>visible &amp; well</p></body></html>
    );
}

test "dump: rel tokens are case insensitive" {
    try testing.expect(hasAsciiToken("alternate MODULEPRELOAD", "modulepreload"));
    try testing.expect(hasAsciiToken("preload stylesheet", "preload"));
    try testing.expect(!hasAsciiToken("prefetch", "preload"));
}

test "dump: render handoff strips navigation and CSP meta policies" {
    try testing.expect(isUnsafeHttpEquiv(" Refresh "));
    try testing.expect(isUnsafeHttpEquiv("CONTENT-SECURITY-POLICY"));
    try testing.expect(isUnsafeHttpEquiv("content-security-policy-report-only"));
    try testing.expect(!isUnsafeHttpEquiv("content-type"));
}

test "dump: live target attribute grammar is narrow" {
    try testing.expect(isLiveTargetAttribute("data-lp-t-0123456789abcdef"));
    try testing.expect(isLiveTargetAttribute("data-lp-k-0123456789abcdef"));
    try testing.expect(isLiveTargetAttribute("DATA-LP-T-0123456789ABCDEF"));
    try testing.expect(!isLiveTargetAttribute("data-lp-t-0123456789abcde"));
    try testing.expect(!isLiveTargetAttribute("data-lp-t-0123456789abcdeg"));
    try testing.expect(!isLiveTargetAttribute("data-lp-target-0123456789abcdef"));
}

test "dump: render CSP precedes base and replaces source policies" {
    var page = try testing.pageTest("dump_render_policy.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{
        .with_base = true,
        .with_render_csp = true,
    }, &aw.writer, frame);
    const html = aw.written();

    const head_pos = std.mem.indexOf(u8, html, "<head>").?;
    const csp_pos = std.mem.indexOf(u8, html, RENDER_CSP_META).?;
    const referrer_pos = std.mem.indexOf(u8, html, RENDER_REFERRER_META).?;
    const base_pos = std.mem.indexOf(u8, html, "<base href=").?;
    try testing.expectEqual(head_pos + "<head>".len, csp_pos);
    try testing.expectEqual(csp_pos + RENDER_CSP_META.len, referrer_pos);
    try testing.expectEqual(referrer_pos + RENDER_REFERRER_META.len, base_pos);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "http-equiv=\"Content-Security-Policy\""));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "name=\"referrer\""));
    try testing.expect(std.mem.indexOf(u8, html, "default-src *") == null);
    try testing.expect(std.mem.indexOf(u8, html, "999999;url=") == null);
    try testing.expect(std.mem.indexOf(u8, html, "unsafe-url") == null);
    try testing.expect(std.mem.indexOf(u8, html, "http-equiv=\"content-type\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "base-uri") == null);
    try testing.expect(std.mem.indexOf(u8, html, "navigate-to") == null);
    try testing.expect(std.mem.indexOf(u8, html, "style-src 'unsafe-inline' data: blob: http: https:") == null);
    try testing.expect(std.mem.indexOf(u8, html, "connect-src 'none'") != null);
}

test "dump: render synthesizes a protected head when the source head is removed" {
    var page = try testing.pageTest("dump_render_policy.html", .{});
    defer page.close();

    const frame = page.frame().?;
    frame.document.is(Node.Document.HTMLDocument).?.getHead().?.remove(frame);

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{
        .with_base = true,
        .with_render_csp = true,
    }, &aw.writer, frame);
    const html = aw.written();

    try testing.expect(std.mem.indexOf(u8, html, "<html><head>") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(
        u8,
        html,
        "http-equiv=\"Content-Security-Policy\"",
    ));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "<base href="));
    const head_end = std.mem.indexOf(u8, html, "</head>").? + "</head>".len;
    const body_start = std.mem.indexOfPos(u8, html, head_end, "<body").?;
    try testing.expectEqual(@as(usize, 0), std.mem.trim(
        u8,
        html[head_end..body_start],
        " \t\r\n",
    ).len);
}

test "dump: direct render resources are explicit and script-free" {
    var page = try testing.pageTest("dump_render_policy.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{
        .with_base = true,
        .with_render_csp = true,
        .direct_render_resources = true,
        .strip = .{ .js = true },
    }, &aw.writer, frame);
    const html = aw.written();

    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "style-src 'unsafe-inline' data: blob: http: https:",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, html, "img-src data: blob: http: https:") != null);
    try testing.expect(std.mem.indexOf(u8, html, "connect-src 'none'") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<script") == null);
}

test "dump: render frames use nested script-free srcdoc snapshots" {
    var page = try testing.pageTest("render/live_session_frame.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{
        .with_base = true,
        .with_frames = true,
        .with_render_csp = true,
        .strip = .{ .js = true, .meta = true },
    }, &aw.writer, frame);
    const html = aw.written();

    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, html, LIVE_FRAME_ATTR));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, html, " srcdoc=\""));
    try testing.expect(std.mem.indexOf(u8, html, LIVE_FRAME_ATTR ++ "=\"spoof\"") == null);
    try testing.expect(std.mem.indexOf(u8, html, " src=\"live_session_frame_child.html\"") == null);
    try testing.expect(std.mem.indexOf(u8, html, " src=\"live_session_frame_grandchild.html\"") == null);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        " srcdoc=\"&lt;p id='srcdoc-content'&gt;srcdoc child&lt;/p&gt;\"",
    ) == null);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "&lt;base href=&quot;http://127.0.0.1:9582/src/browser/tests/render/live_session_frame_child.html&quot;&gt;",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "&amp;lt;base href=&amp;quot;http://127.0.0.1:9582/src/browser/tests/render/live_session_frame_grandchild.html&amp;quot;&amp;gt;",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "&lt;link rel=&quot;stylesheet&quot; href=&quot;live_session_frame.css&quot;&gt;",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "&amp;lt;link rel=&amp;quot;stylesheet&amp;quot; href=&amp;quot;live_session_frame.css&amp;quot;&amp;gt;",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "&lt;meta name=&quot;referrer&quot; content=&quot;no-referrer&quot;&gt;",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "&amp;lt;meta name=&amp;quot;referrer&amp;quot; content=&amp;quot;no-referrer&amp;quot;&amp;gt;",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, html, "unsafe-url") == null);
    try testing.expect(std.mem.indexOf(u8, html, "content=&quot;origin&quot;") == null);
    try testing.expect(std.mem.indexOf(u8, html, "<script") == null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;script") == null);
    try testing.expect(std.mem.indexOf(u8, html, "&amp;lt;script") == null);
    try testing.expect(std.mem.indexOf(u8, html, "frame-src 'self'") != null);
    try testing.expect(std.mem.indexOf(u8, html, "frame-src http:") == null);
    try testing.expect(std.mem.indexOf(u8, html, "frame-src https:") == null);
    try testing.expect(std.mem.indexOf(u8, html, "sandbox=\"allow-scripts\"") == null);
    try testing.expect(std.mem.count(
        u8,
        html,
        "sandbox=\"allow-same-origin\"",
    ) >= 2);
}

test "dump: render snapshot serializes initialized style CSSOM" {
    var page = try testing.pageTest("render/cssom_style_snapshot.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{
        .with_render_csp = true,
        .strip = .{ .js = true },
    }, &aw.writer, frame);
    const html = aw.written();

    try testing.expect(std.mem.indexOf(u8, html, ".deleted") == null);
    try testing.expect(std.mem.indexOf(u8, html, ".stale") == null);
    try testing.expect(std.mem.indexOf(u8, html, "@media screen { .media { display: block; } }") != null);
    try testing.expect(std.mem.indexOf(u8, html, ".kept { color: green; }") != null);
    try testing.expect(std.mem.indexOf(u8, html, ".replacement::before { content: \"\\3C /STYLE>\"; }") != null);
    try testing.expect(std.mem.indexOf(u8, html, "@keyframes spin { from { opacity: 0; } to { opacity: 1; } }") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        html,
        "<style id=\"raw\" type=\"text/plain\">\n    .raw{content:\"original\";}\n  </style>",
    ) != null);
}

test "dump: render snapshot inlines mutated linked CSSOM" {
    testing.test_session.load_external_stylesheets = true;
    defer testing.test_session.load_external_stylesheets = false;

    var page = try testing.pageTest("css/external_stylesheet.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const sheets = try frame.document.getStyleSheets(frame);
    const sheet = sheets.item(0).?;
    const rules = try sheet.getCssRules(frame);
    const style_rule = switch (rules._rules.items[0]._type) {
        .style => |style| style,
        else => unreachable,
    };
    const style = try style_rule.getStyle(frame);
    try style.setNamed("display", "block", frame);
    _ = try sheet.insertRule(".linked-added { color: green; }", null, frame);

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{
        .with_render_csp = true,
        .strip = .{ .js = true },
    }, &aw.writer, frame);
    const html = aw.written();

    try testing.expect(std.mem.indexOf(u8, html, "<link id=\"ext\"") == null);
    try testing.expect(std.mem.indexOf(u8, html, ".ext-hide { display: block; }") != null);
    try testing.expect(std.mem.indexOf(u8, html, ".linked-added { color: green; }") != null);

    sheet.setDisabled(true, frame);
    var disabled: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{
        .with_render_csp = true,
        .strip = .{ .js = true },
    }, &disabled.writer, frame);
    try testing.expect(std.mem.indexOf(u8, disabled.written(), ".linked-added") == null);
}

test "dump: live form state reflects properties without passwords" {
    var page = try testing.pageTest("dump_live_form.html", .{});
    defer page.close();

    const frame = page.frame().?;
    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.document, .{
        .strip = .{ .js = true },
        .live_form_state = true,
    }, &aw.writer, frame);
    const html = aw.written();

    try testing.expect(std.mem.indexOf(u8, html, "id=\"text\" value=\"A&amp;B&quot;\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "default-secret") == null);
    try testing.expect(std.mem.indexOf(u8, html, "runtime-secret") == null);
    try testing.expect(std.mem.indexOf(u8, html, "spoof-file-value") == null);
    try testing.expect(std.mem.indexOf(u8, html, "<input id=\"file\" type=\"file\">") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"check\" type=\"checkbox\" checked") == null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"check\" type=\"checkbox\" value=\"runtime-check\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"radio\" type=\"radio\" checked value=\"runtime-radio\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"indeterminate\" type=\"checkbox\" value=\"on\" " ++ LIVE_INDETERMINATE_ATTR) != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"not-indeterminate\" type=\"checkbox\" value=\"on\" " ++ LIVE_INDETERMINATE_ATTR) == null);
    try testing.expect(std.mem.indexOf(u8, html, "<option value=\"a\">A</option>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<option value=\"b\" selected>B</option>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<select id=\"none\" " ++ LIVE_SELECTED_NONE_ATTR) != null);
    try testing.expect(std.mem.indexOf(u8, html, "<select id=\"selected-spoof\" " ++ LIVE_SELECTED_NONE_ATTR) == null);
    try testing.expect(std.mem.indexOf(u8, html, "<option value=\"same\" selected>First</option>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<option value=\"same\">Second</option>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<textarea id=\"notes\">&lt;new&gt;</textarea>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<textarea id=\"leading\">\n\nlead</textarea>") != null);
}

test "dump: strip.css removes style and stylesheet links" {
    try expectDump(.{ .strip = .{ .css = true } },
        \\<!DOCTYPE html>
        \\<html><head><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: strip.ui removes css plus visual elements" {
    try expectDump(.{ .strip = .{ .ui = true } },
        \\<!DOCTYPE html>
        \\<html><head><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: strip.invisible removes author display:none elements" {
    try expectDump(.{ .strip = .{ .invisible = true } },
        \\<!DOCTYPE html>
        \\<html><head><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"><script>var a=1;</script></head><body><h1>Title</h1><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}
