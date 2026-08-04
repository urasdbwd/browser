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

const std = @import("std");

const js = @import("../../js/js.zig");

const color = @import("../../color.zig");

const Frame = @import("../../Frame.zig");
const Canvas = @import("../element/html/Canvas.zig");
const Image = @import("../element/html/Image.zig");
const ImageData = @import("../ImageData.zig");
const CanvasGradient = @import("CanvasGradient.zig");
const TextMetrics = @import("TextMetrics.zig");

const Execution = js.Execution;

/// Fingerprint-grade 2D canvas context. Drawing commands update a stable seed
/// used by getImageData / HTMLCanvasElement.toDataURL — no real GPU raster.
const CanvasRenderingContext2D = @This();

_canvas: *Canvas,
_fill_style: color.RGBA = color.RGBA.Named.black,
/// FNV-1a running hash of drawing ops for stable fingerprints.
/// Initialized from browser fingerprint profile when the 2d context is created.
_fp_seed: u64 = 0xcbf29ce484222325,
_dirty: bool = false,
_font: [96]u8 = "10px sans-serif".* ++ .{0} ** 81,
_font_len: u8 = 15,
_ops: [ops_capacity]u8 = undefined,
_ops_len: u16 = 0,
_ops_sent: u16 = 0,
_ops_dropped: bool = false,

/// Replay log capacity, in bytes.
///
/// Lightpanda has no rasterizer, so a canvas can never be painted here. What we
/// can do is record the 2D op stream and let the viewer's real browser replay it
/// onto a real canvas. Ops accumulate as JSON array elements *without* the
/// enclosing brackets, so a snapshot can splice them straight into an attribute
/// and the client can `JSON.parse("[" + value + "]")`.
///
/// ponytail: fixed 8 KiB per context, no eviction — once full we stop recording
/// and latch `_ops_dropped` so the client can tell the frame is partial. A
/// clearRect covering the whole canvas resets the log, which is exactly what an
/// animation loop does every frame, so a steady-state game never approaches the
/// cap. Upgrade path if a real app does overflow: give ops their own WebSocket
/// frame and stream them continuously instead of riding on the snapshot.
pub const ops_capacity = 8 * 1024;

pub fn getCanvas(self: *const CanvasRenderingContext2D) *Canvas {
    return self._canvas;
}

/// Ops recorded but not yet handed to a snapshot.
pub fn pendingOps(self: *const CanvasRenderingContext2D) []const u8 {
    const pending = self._ops[self._ops_sent..self._ops_len];
    // The separator is written ahead of its op, so a slice that starts at a
    // delivery boundary opens with one. Leaving it in would make the client's
    // JSON.parse("[" ++ value ++ "]") fail on every incremental snapshot.
    if (pending.len > 0 and pending[0] == ',') return pending[1..];
    return pending;
}

/// Marks everything recorded so far as delivered to the client.
pub fn markOpsSent(self: *CanvasRenderingContext2D) void {
    self._ops_sent = self._ops_len;
}

pub fn opsDropped(self: *const CanvasRenderingContext2D) bool {
    return self._ops_dropped;
}

/// Appends one JSON array element to the replay log. Anything that does not fit
/// is dropped rather than truncated — a half-written op would break the client's
/// JSON.parse, whereas a missing one only costs fidelity.
/// Longest image URL worth replaying; also bounds the `record` scratch buffer.
const max_image_src = 512;

fn record(self: *CanvasRenderingContext2D, comptime fmt: []const u8, args: anytype) void {
    var buf: [2 * max_image_src + 128]u8 = undefined;
    const chunk = std.fmt.bufPrint(&buf, fmt, args) catch {
        self._ops_dropped = true;
        return;
    };
    const separator: usize = if (self._ops_len == 0) 0 else 1;
    if (@as(usize, self._ops_len) + separator + chunk.len > ops_capacity) {
        self._ops_dropped = true;
        return;
    }
    if (separator == 1) {
        self._ops[self._ops_len] = ',';
        self._ops_len += 1;
    }
    @memcpy(self._ops[self._ops_len..][0..chunk.len], chunk);
    self._ops_len += @intCast(chunk.len);
}

/// A clearRect covering the whole canvas hides every earlier op, so the log
/// restarts from a single clear. This is what keeps an animation loop bounded.
fn resetOps(self: *CanvasRenderingContext2D) void {
    self._ops_len = 0;
    self._ops_sent = 0;
    self._ops_dropped = false;
    self.record("[\"z\"]", .{});
}

/// JSON has no encoding for non-finite numbers; a replayed 0 beats a parse error.
fn finite(v: f64) f64 {
    return if (std.math.isFinite(v)) v else 0;
}

/// Minimal JSON string escaping. Over-long values are truncated instead of
/// dropped so one stray huge string cannot starve the rest of the log.
fn jsonString(buf: []u8, value: []const u8) []const u8 {
    var w: usize = 0;
    buf[w] = '"';
    w += 1;
    for (value) |c| {
        if (w + 8 > buf.len) break;
        switch (c) {
            '"', '\\' => {
                buf[w] = '\\';
                buf[w + 1] = c;
                w += 2;
            },
            '\n' => {
                buf[w] = '\\';
                buf[w + 1] = 'n';
                w += 2;
            },
            '\r' => {
                buf[w] = '\\';
                buf[w + 1] = 'r';
                w += 2;
            },
            '\t' => {
                buf[w] = '\\';
                buf[w + 1] = 't';
                w += 2;
            },
            else => {
                if (c < 0x20) {
                    const escaped = std.fmt.bufPrint(buf[w..], "\\u{x:0>4}", .{c}) catch break;
                    w += escaped.len;
                } else {
                    buf[w] = c;
                    w += 1;
                }
            },
        }
    }
    buf[w] = '"';
    w += 1;
    return buf[0..w];
}

fn recordColor(self: *CanvasRenderingContext2D, comptime op: []const u8, rgba: color.RGBA) void {
    var text: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);
    rgba.format(&w) catch {
        self._ops_dropped = true;
        return;
    };
    var escaped: [160]u8 = undefined;
    self.record("[\"" ++ op ++ "\",{s}]", .{jsonString(&escaped, w.buffered())});
}

pub fn fingerprintSeed(self: *const CanvasRenderingContext2D) u64 {
    return self._fp_seed;
}

fn mix(self: *CanvasRenderingContext2D, v: u64) void {
    self._dirty = true;
    self._fp_seed ^= v;
    self._fp_seed *%= 0x100000001b3;
}

fn mixF(self: *CanvasRenderingContext2D, f: f64) void {
    self.mix(@as(u64, @bitCast(f)));
}

fn mixBytes(self: *CanvasRenderingContext2D, bytes: []const u8) void {
    for (bytes) |b| {
        self._fp_seed ^= b;
        self._fp_seed *%= 0x100000001b3;
    }
}

fn mixColor(self: *CanvasRenderingContext2D) void {
    self.mix(@as(u32, self._fill_style.r) |
        (@as(u32, self._fill_style.g) << 8) |
        (@as(u32, self._fill_style.b) << 16) |
        (@as(u32, self._fill_style.a) << 24));
}

pub fn getFillStyle(self: *const CanvasRenderingContext2D, exec: *Execution) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(exec.local_arena);
    try self._fill_style.format(&w.writer);
    return w.written();
}

pub fn setFillStyle(
    self: *CanvasRenderingContext2D,
    value: []const u8,
) !void {
    self._fill_style = color.RGBA.parse(value) catch self._fill_style;
    self.recordColor("FS", self._fill_style);
}

pub fn setStrokeStyle(self: *CanvasRenderingContext2D, value: []const u8) void {
    self.mixBytes(value);
}

pub fn getFont(self: *const CanvasRenderingContext2D) []const u8 {
    return self._font[0..self._font_len];
}

pub fn setFont(self: *CanvasRenderingContext2D, value: []const u8) void {
    const n = @min(value.len, self._font.len);
    @memcpy(self._font[0..n], value[0..n]);
    self._font_len = @intCast(n);
    var escaped: [224]u8 = undefined;
    self.record("[\"FO\",{s}]", .{jsonString(&escaped, self.getFont())});
}

const WidthOrImageData = union(enum) {
    width: u32,
    image_data: *ImageData,
};

pub fn createImageData(
    _: *const CanvasRenderingContext2D,
    width_or_image_data: WidthOrImageData,
    maybe_height: ?u32,
    maybe_settings: ?ImageData.ConstructorSettings,
    exec: *Execution,
) !*ImageData {
    switch (width_or_image_data) {
        .width => |width| {
            const height = maybe_height orelse return error.TypeError;
            return ImageData.init(width, height, maybe_settings, exec);
        },
        .image_data => |image_data| {
            return ImageData.init(image_data._width, image_data._height, null, exec);
        },
    }
}

pub fn putImageData(self: *CanvasRenderingContext2D, data: *ImageData, dx: f64, dy: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64) void {
    self.mix(data._width);
    self.mix(data._height);
    self.mixF(dx);
    self.mixF(dy);
}

pub fn drawImage(self: *CanvasRenderingContext2D, image: js.Value, dx: f64, dy: f64, dw: ?f64, dh: ?f64, a5: ?f64, a6: ?f64, a7: ?f64, a8: ?f64, frame: *Frame) void {
    self.mixF(dx);
    self.mixF(dy);
    if (dw) |v| self.mixF(v);
    if (dh) |v| self.mixF(v);

    // Reference the bitmap by URL and let the client re-fetch it from origin —
    // the pixels never touch the wire. Sources we cannot name (a canvas, a
    // video) are skipped rather than replayed as a blank.
    const img = image.toZig(*Image) catch return;
    const src = img.getSrc(frame) catch return;
    // An inline data: URI is the bitmap, so replaying it would put the pixels on
    // the wire once per frame — exactly what naming images by URL avoids.
    if (src.len == 0 or src.len > max_image_src) return;

    var escaped: [2 * max_image_src]u8 = undefined;
    const quoted = jsonString(&escaped, src);
    // Trailing coordinates are positional; emit exactly the arity we received so
    // the client can forward them straight to the real drawImage.
    if (a8) |_| {
        self.record("[\"di\",{s},{d},{d},{d},{d},{d},{d},{d},{d}]", .{
            quoted,              finite(dx),          finite(dy),          finite(dw orelse 0),
            finite(dh orelse 0), finite(a5 orelse 0), finite(a6 orelse 0), finite(a7 orelse 0),
            finite(a8.?),
        });
    } else if (dh) |_| {
        self.record("[\"di\",{s},{d},{d},{d},{d}]", .{
            quoted, finite(dx), finite(dy), finite(dw orelse 0), finite(dh.?),
        });
    } else {
        self.record("[\"di\",{s},{d},{d}]", .{ quoted, finite(dx), finite(dy) });
    }
}

pub fn getImageData(
    self: *const CanvasRenderingContext2D,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    exec: *Execution,
) !*ImageData {
    if (sw <= 0 or sh <= 0) {
        return error.IndexSizeError;
    }
    const image = try ImageData.init(@intCast(sw), @intCast(sh), null, exec);
    // Undrawn canvas: transparent black (spec). After drawing: stable fingerprint pixels.
    if (!self._dirty) return image;
    var rng = self._fp_seed ^ (@as(u64, @bitCast(@as(i64, sx))) *% 0x9e3779b97f4a7c15) ^ (@as(u64, @bitCast(@as(i64, sy))) *% 0xbf58476d1ce4e5b9);
    const local = exec.js.local.?;
    const pixels = image._data.local(local).slice();
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        pixels[i] = @truncate(rng);
        pixels[i + 1] = @truncate(rng >> 8);
        pixels[i + 2] = @truncate(rng >> 16);
        pixels[i + 3] = 255;
    }
    return image;
}

pub fn createLinearGradient(self: *CanvasRenderingContext2D, x0: f64, y0: f64, x1: f64, y1: f64, exec: *Execution) !*CanvasGradient {
    var seed: u64 = self._fp_seed ^ 0x4c494e45;
    seed = fnvMix(seed, @as(u64, @bitCast(x0)));
    seed = fnvMix(seed, @as(u64, @bitCast(y0)));
    seed = fnvMix(seed, @as(u64, @bitCast(x1)));
    seed = fnvMix(seed, @as(u64, @bitCast(y1)));
    return exec._factory.create(CanvasGradient{ ._kind = .linear, ._seed = seed });
}

pub fn createRadialGradient(self: *CanvasRenderingContext2D, x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64, exec: *Execution) !*CanvasGradient {
    var seed: u64 = self._fp_seed ^ 0x52414449;
    seed = fnvMix(seed, @as(u64, @bitCast(x0)));
    seed = fnvMix(seed, @as(u64, @bitCast(y0)));
    seed = fnvMix(seed, @as(u64, @bitCast(r0)));
    seed = fnvMix(seed, @as(u64, @bitCast(x1)));
    seed = fnvMix(seed, @as(u64, @bitCast(y1)));
    seed = fnvMix(seed, @as(u64, @bitCast(r1)));
    return exec._factory.create(CanvasGradient{ ._kind = .radial, ._seed = seed });
}

pub fn measureText(self: *const CanvasRenderingContext2D, text: []const u8, exec: *Execution) !*TextMetrics {
    const font = self.getFont();
    const size = parseFontSize(font);
    const family_factor = fontFamilyFactor(font);
    // Per-character advance with font-dependent spacing so font probes diverge.
    var width: f64 = 0;
    for (text) |c| {
        const base: f64 = if (c < 128) char_widths[c] else 0.6;
        width += base * size * family_factor;
    }
    const ascent = size * 0.8 * family_factor;
    const descent = size * 0.2 * family_factor;
    return exec._factory.create(TextMetrics{
        ._width = width,
        ._actual_bounding_box_left = 0,
        ._actual_bounding_box_right = width,
        ._font_bounding_box_ascent = ascent,
        ._font_bounding_box_descent = descent,
        ._actual_bounding_box_ascent = ascent * 0.95,
        ._actual_bounding_box_descent = descent,
        ._em_height_ascent = ascent,
        ._em_height_descent = descent,
        ._hanging_baseline = ascent * 0.8,
        ._alphabetic_baseline = 0,
        ._ideographic_baseline = -descent * 0.5,
    });
}

// Approximate advance widths as fraction of em for ASCII (mono-ish fallback).
const char_widths: [128]f64 = blk: {
    var w: [128]f64 = .{0.5} ** 128;
    // Digits / caps a bit wider; i/l/t narrower — enough to fingerprint.
    for ('A'..('Z' + 1)) |c| w[c] = 0.66;
    for ('a'..('z' + 1)) |c| w[c] = 0.56;
    w['i'] = 0.28;
    w['l'] = 0.28;
    w['t'] = 0.35;
    w['f'] = 0.35;
    w['m'] = 0.85;
    w['w'] = 0.85;
    w['W'] = 0.9;
    w['M'] = 0.9;
    w[' '] = 0.3;
    break :blk w;
};

fn parseFontSize(font: []const u8) f64 {
    // Scan for first number before "px"
    var i: usize = 0;
    while (i < font.len) : (i += 1) {
        if (font[i] >= '0' and font[i] <= '9') {
            var n: f64 = 0;
            while (i < font.len and font[i] >= '0' and font[i] <= '9') : (i += 1) {
                n = n * 10 + @as(f64, @floatFromInt(font[i] - '0'));
            }
            if (i < font.len and font[i] == '.') {
                i += 1;
                var place: f64 = 0.1;
                while (i < font.len and font[i] >= '0' and font[i] <= '9') : (i += 1) {
                    n += @as(f64, @floatFromInt(font[i] - '0')) * place;
                    place *= 0.1;
                }
            }
            return if (n > 0) n else 10;
        }
    }
    return 10;
}

fn fontFamilyFactor(font: []const u8) f64 {
    // Lowercased substring checks for common OS fonts used by fingerprint scripts.
    var lower_buf: [96]u8 = undefined;
    const n = @min(font.len, lower_buf.len);
    for (font[0..n], 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..n];

    // Windows core
    if (std.mem.indexOf(u8, lower, "arial") != null) return 1.00;
    if (std.mem.indexOf(u8, lower, "calibri") != null) return 0.97;
    if (std.mem.indexOf(u8, lower, "segoe") != null) return 0.99;
    if (std.mem.indexOf(u8, lower, "tahoma") != null) return 0.96;
    if (std.mem.indexOf(u8, lower, "verdana") != null) return 1.05;
    if (std.mem.indexOf(u8, lower, "times") != null) return 0.94;
    if (std.mem.indexOf(u8, lower, "georgia") != null) return 0.98;
    if (std.mem.indexOf(u8, lower, "courier") != null) return 0.90;
    if (std.mem.indexOf(u8, lower, "consolas") != null) return 0.91;
    if (std.mem.indexOf(u8, lower, "comic") != null) return 1.08;
    if (std.mem.indexOf(u8, lower, "impact") != null) return 0.88;
    // macOS
    if (std.mem.indexOf(u8, lower, "helvetica") != null) return 0.99;
    if (std.mem.indexOf(u8, lower, "menlo") != null) return 0.92;
    if (std.mem.indexOf(u8, lower, "monaco") != null) return 0.93;
    if (std.mem.indexOf(u8, lower, "geneva") != null) return 0.98;
    // Linux
    if (std.mem.indexOf(u8, lower, "dejavu") != null) return 1.01;
    if (std.mem.indexOf(u8, lower, "liberation") != null) return 1.00;
    if (std.mem.indexOf(u8, lower, "ubuntu") != null) return 0.98;
    if (std.mem.indexOf(u8, lower, "noto") != null) return 1.02;
    if (std.mem.indexOf(u8, lower, "serif") != null) return 0.95;
    if (std.mem.indexOf(u8, lower, "mono") != null) return 0.90;
    return 1.0; // sans-serif default
}

fn fnvMix(h: u64, v: u64) u64 {
    var x = h ^ v;
    x *%= 0x100000001b3;
    return x;
}

pub fn save(self: *CanvasRenderingContext2D) void {
    self.record("[\"sv\"]", .{});
}
pub fn restore(self: *CanvasRenderingContext2D) void {
    self.record("[\"rs\"]", .{});
}
pub fn scale(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.record("[\"sc\",{d},{d}]", .{ finite(x), finite(y) });
}
pub fn rotate(self: *CanvasRenderingContext2D, a: f64) void {
    self.mixF(a);
    self.record("[\"ro\",{d}]", .{finite(a)});
}
pub fn translate(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.record("[\"tr\",{d},{d}]", .{ finite(x), finite(y) });
}
pub fn transform(self: *CanvasRenderingContext2D, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
    self.mixF(a);
    self.mixF(b);
    self.mixF(c);
    self.mixF(d);
    self.mixF(e);
    self.mixF(f);
    self.record("[\"tf\",{d},{d},{d},{d},{d},{d}]", .{
        finite(a), finite(b), finite(c), finite(d), finite(e), finite(f),
    });
}
pub fn setTransform(self: *CanvasRenderingContext2D, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
    self.mixF(a);
    self.mixF(b);
    self.mixF(c);
    self.mixF(d);
    self.mixF(e);
    self.mixF(f);
    self.record("[\"st\",{d},{d},{d},{d},{d},{d}]", .{
        finite(a), finite(b), finite(c), finite(d), finite(e), finite(f),
    });
}
pub fn resetTransform(self: *CanvasRenderingContext2D) void {
    self.record("[\"rt\"]", .{});
}
pub fn clearRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.mixF(w);
    self.mixF(h);
    self.mix(1);
    // A clear that covers the whole canvas makes every earlier op invisible.
    // Collapsing the log here is what keeps a 60fps animation loop bounded.
    if (x <= 0 and y <= 0 and
        w >= @as(f64, @floatFromInt(self._canvas.getWidth())) and
        h >= @as(f64, @floatFromInt(self._canvas.getHeight())))
    {
        self.resetOps();
        return;
    }
    self.record("[\"cr\",{d},{d},{d},{d}]", .{ finite(x), finite(y), finite(w), finite(h) });
}
pub fn fillRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self.mixColor();
    self.mixF(x);
    self.mixF(y);
    self.mixF(w);
    self.mixF(h);
    self.mix(2);
    self.record("[\"fr\",{d},{d},{d},{d}]", .{ finite(x), finite(y), finite(w), finite(h) });
}
pub fn strokeRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.mixF(w);
    self.mixF(h);
    self.mix(3);
    self.record("[\"sr\",{d},{d},{d},{d}]", .{ finite(x), finite(y), finite(w), finite(h) });
}
pub fn beginPath(self: *CanvasRenderingContext2D) void {
    self.record("[\"bp\"]", .{});
}
pub fn closePath(self: *CanvasRenderingContext2D) void {
    self.record("[\"cp\"]", .{});
}
pub fn moveTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.record("[\"mv\",{d},{d}]", .{ finite(x), finite(y) });
}
pub fn lineTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.record("[\"ln\",{d},{d}]", .{ finite(x), finite(y) });
}
pub fn quadraticCurveTo(self: *CanvasRenderingContext2D, cpx: f64, cpy: f64, x: f64, y: f64) void {
    self.mixF(cpx);
    self.mixF(cpy);
    self.mixF(x);
    self.mixF(y);
    self.record("[\"qc\",{d},{d},{d},{d}]", .{ finite(cpx), finite(cpy), finite(x), finite(y) });
}
pub fn bezierCurveTo(self: *CanvasRenderingContext2D, cp1x: f64, cp1y: f64, cp2x: f64, cp2y: f64, x: f64, y: f64) void {
    self.mixF(cp1x);
    self.mixF(cp1y);
    self.mixF(cp2x);
    self.mixF(cp2y);
    self.mixF(x);
    self.mixF(y);
    self.record("[\"bc\",{d},{d},{d},{d},{d},{d}]", .{
        finite(cp1x), finite(cp1y), finite(cp2x), finite(cp2y), finite(x), finite(y),
    });
}
pub fn arc(self: *CanvasRenderingContext2D, x: f64, y: f64, r: f64, a0: f64, a1: f64, ccw: ?bool) void {
    self.mixF(x);
    self.mixF(y);
    self.mixF(r);
    self.mixF(a0);
    self.mixF(a1);
    self.record("[\"ar\",{d},{d},{d},{d},{d},{}]", .{
        finite(x), finite(y), finite(r), finite(a0), finite(a1), ccw orelse false,
    });
}
pub fn arcTo(self: *CanvasRenderingContext2D, x1: f64, y1: f64, x2: f64, y2: f64, r: f64) void {
    self.mixF(x1);
    self.mixF(y1);
    self.mixF(x2);
    self.mixF(y2);
    self.mixF(r);
    self.record("[\"at\",{d},{d},{d},{d},{d}]", .{
        finite(x1), finite(y1), finite(x2), finite(y2), finite(r),
    });
}
pub fn rect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    self.mixF(x);
    self.mixF(y);
    self.mixF(w);
    self.mixF(h);
    self.record("[\"re\",{d},{d},{d},{d}]", .{ finite(x), finite(y), finite(w), finite(h) });
}
pub fn fill(self: *CanvasRenderingContext2D) void {
    self.mixColor();
    self.mix(4);
    self.record("[\"fl\"]", .{});
}
pub fn stroke(self: *CanvasRenderingContext2D) void {
    self.mix(5);
    self.record("[\"sk\"]", .{});
}
pub fn clip(self: *CanvasRenderingContext2D) void {
    self.record("[\"cl\"]", .{});
}
pub fn fillText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, max_width: ?f64) void {
    self.mixColor();
    self.mixBytes(text);
    self.mixBytes(self.getFont());
    self.mixF(x);
    self.mixF(y);
    if (max_width) |mw| self.mixF(mw);
    self.mix(6);
    self.recordText("ft", text, x, y, max_width);
}
pub fn strokeText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, max_width: ?f64) void {
    self.mixBytes(text);
    self.mixBytes(self.getFont());
    self.mixF(x);
    self.mixF(y);
    if (max_width) |mw| self.mixF(mw);
    self.mix(7);
    self.recordText("sx", text, x, y, max_width);
}

fn recordText(
    self: *CanvasRenderingContext2D,
    comptime op: []const u8,
    text: []const u8,
    x: f64,
    y: f64,
    max_width: ?f64,
) void {
    var escaped: [320]u8 = undefined;
    const quoted = jsonString(&escaped, text);
    if (max_width) |mw| {
        self.record("[\"" ++ op ++ "\",{s},{d},{d},{d}]", .{ quoted, finite(x), finite(y), finite(mw) });
    } else {
        self.record("[\"" ++ op ++ "\",{s},{d},{d}]", .{ quoted, finite(x), finite(y) });
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "CanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(CanvasRenderingContext2D.getCanvas, null, .{});
    pub const font = bridge.accessor(CanvasRenderingContext2D.getFont, CanvasRenderingContext2D.setFont, .{});
    // ponytail: strokeStyle/lineWidth/globalAlpha stay plain JS properties, so
    // the server never sees them and the replay log cannot carry them — strokes
    // repaint on the client with default black at 1px and no alpha. Converting
    // them to accessors is what you would reach for, and it does record them,
    // but it also breaks JS class registration badly enough that unrelated pages
    // stop building a DOM (four dump tests and an Input test fail). Upgrade path:
    // fix the accessor registration in js/bridge.zig first, then flip these.
    pub const globalAlpha = bridge.property(1.0, .{ .template = false, .readonly = false });
    pub const globalCompositeOperation = bridge.property("source-over", .{ .template = false, .readonly = false });
    pub const strokeStyle = bridge.property("#000000", .{ .template = false, .readonly = false });
    pub const lineWidth = bridge.property(1.0, .{ .template = false, .readonly = false });
    pub const lineCap = bridge.property("butt", .{ .template = false, .readonly = false });
    pub const lineJoin = bridge.property("miter", .{ .template = false, .readonly = false });
    pub const miterLimit = bridge.property(10.0, .{ .template = false, .readonly = false });
    pub const textAlign = bridge.property("start", .{ .template = false, .readonly = false });
    pub const textBaseline = bridge.property("alphabetic", .{ .template = false, .readonly = false });

    pub const fillStyle = bridge.accessor(CanvasRenderingContext2D.getFillStyle, CanvasRenderingContext2D.setFillStyle, .{});
    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{});
    pub const createLinearGradient = bridge.function(CanvasRenderingContext2D.createLinearGradient, .{});
    pub const createRadialGradient = bridge.function(CanvasRenderingContext2D.createRadialGradient, .{});
    pub const measureText = bridge.function(CanvasRenderingContext2D.measureText, .{});

    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{});
    pub const drawImage = bridge.function(CanvasRenderingContext2D.drawImage, .{});
    pub const getImageData = bridge.function(CanvasRenderingContext2D.getImageData, .{});
    pub const save = bridge.function(CanvasRenderingContext2D.save, .{});
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{});
    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{});
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{});
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{});
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{});
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{});
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{});
    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{});
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{});
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{});
    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{});
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{});
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{});
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{});
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{});
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{});
    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{});
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{});
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{});
    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{});
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{});
    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{});
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{});
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}

test "CanvasRenderingContext2D: op log ships only what is new" {
    // _canvas is only dereferenced by clearRect, which this test never calls.
    var ctx: CanvasRenderingContext2D = .{ ._canvas = undefined };

    try testing.expectString("", ctx.pendingOps());

    ctx.fillRect(1, 2, 3, 4);
    try testing.expectString("[\"fr\",1,2,3,4]", ctx.pendingOps());

    // Delivered ops are not resent; only what came after them is.
    ctx.markOpsSent();
    try testing.expectString("", ctx.pendingOps());
    ctx.stroke();
    try testing.expectString("[\"sk\"]", ctx.pendingOps());

    // ...while the whole log still reads back as one JSON array body.
    ctx.markOpsSent();
    try testing.expectString("[\"fr\",1,2,3,4],[\"sk\"]", ctx._ops[0..ctx._ops_len]);
    try testing.expectEqual(false, ctx.opsDropped());
}

test "CanvasRenderingContext2D: op log is bounded and latches the overflow" {
    var ctx: CanvasRenderingContext2D = .{ ._canvas = undefined };

    for (0..ops_capacity) |_| ctx.fillRect(1, 2, 3, 4);

    try testing.expect(ctx._ops_len <= ops_capacity);
    try testing.expectEqual(true, ctx.opsDropped());
    // A partial op would break the client's JSON.parse, so the tail must always
    // be a complete element.
    try testing.expectEqual(@as(u8, ']'), ctx._ops[ctx._ops_len - 1]);
}

test "CanvasRenderingContext2D: collapsing the log restarts it from a clear" {
    var ctx: CanvasRenderingContext2D = .{ ._canvas = undefined };

    // Overflow first, so the reset is shown to clear the dropped latch too.
    for (0..ops_capacity) |_| ctx.fillRect(1, 2, 3, 4);
    ctx.markOpsSent();
    try testing.expectString("", ctx.pendingOps());
    try testing.expectEqual(true, ctx.opsDropped());

    ctx.resetOps();
    // Everything earlier is invisible now, so the log restarts from the clear
    // and is re-sent in full — the client's canvas has to be cleared as well.
    try testing.expectString("[\"z\"]", ctx.pendingOps());
    try testing.expectEqual(false, ctx.opsDropped());
    try testing.expectEqual(@as(u16, 0), ctx._ops_sent);

    // A partial clear is just another op and keeps the history.
    ctx.markOpsSent();
    ctx.record("[\"cr\",{d},{d},{d},{d}]", .{ 0, 0, 10, 10 });
    try testing.expectString("[\"cr\",0,0,10,10]", ctx.pendingOps());
}

test "CanvasRenderingContext2D: recorded strings stay valid JSON" {
    var ctx: CanvasRenderingContext2D = .{ ._canvas = undefined };

    ctx.fillText("say \"hi\"\n\tnow", 1, 2, null);
    try testing.expectString(
        "[\"ft\",\"say \\\"hi\\\"\\n\\tnow\",1,2]",
        ctx.pendingOps(),
    );

    // Non-finite coordinates have no JSON spelling and must not poison the log.
    ctx.markOpsSent();
    ctx.moveTo(std.math.inf(f64), std.math.nan(f64));
    try testing.expectString("[\"mv\",0,0]", ctx.pendingOps());
}
