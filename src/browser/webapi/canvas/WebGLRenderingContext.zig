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
const Frame = @import("../../Frame.zig");
const Canvas = @import("../element/html/Canvas.zig");

pub fn registerTypes() []const type {
    return &.{
        WebGLRenderingContext,
        Extension.Type.WEBGL_debug_renderer_info,
        Extension.Type.WEBGL_lose_context,
    };
}

const WebGLRenderingContext = @This();

/// Parent canvas (spec requires .canvas).
_canvas: *Canvas,
/// Seeded from the browser fingerprint profile when the context is created;
/// drives readPixels / toDataURL so the GPU probe isn't an all-zero buffer.
_fp_seed: u64 = 0xcbf29ce484222325,

const VENDOR = "WebKit";
const RENDERER = "WebKit WebGL";
const VERSION = "WebGL 1.0 (OpenGL ES 2.0 Chromium)";
const SHADING_LANGUAGE_VERSION = "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)";

// GLenum constants used by fingerprint scripts
const GL_VENDOR: u32 = 0x1F00;
const GL_RENDERER: u32 = 0x1F01;
const GL_VERSION: u32 = 0x1F02;
const GL_SHADING_LANGUAGE_VERSION: u32 = 0x8B8C;
const GL_UNMASKED_VENDOR: u32 = 0x9245;
const GL_UNMASKED_RENDERER: u32 = 0x9246;
const GL_MAX_TEXTURE_SIZE: u32 = 0x0D33;
const GL_MAX_CUBE_MAP_TEXTURE_SIZE: u32 = 0x851C;
const GL_MAX_RENDERBUFFER_SIZE: u32 = 0x84E8;
const GL_MAX_VERTEX_ATTRIBS: u32 = 0x8869;
const GL_MAX_VERTEX_UNIFORM_VECTORS: u32 = 0x8DFB;
const GL_MAX_VARYING_VECTORS: u32 = 0x8DFC;
const GL_MAX_FRAGMENT_UNIFORM_VECTORS: u32 = 0x8DFD;
const GL_MAX_TEXTURE_IMAGE_UNITS: u32 = 0x8872;
const GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS: u32 = 0x8B4D;
const GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS: u32 = 0x8B4C;
const GL_ALIASED_LINE_WIDTH_RANGE: u32 = 0x846E;
const GL_ALIASED_POINT_SIZE_RANGE: u32 = 0x846D;
const GL_MAX_VIEWPORT_DIMS: u32 = 0x0D3A;
const GL_RED_BITS: u32 = 0x0D52;
const GL_GREEN_BITS: u32 = 0x0D53;
const GL_BLUE_BITS: u32 = 0x0D54;
const GL_ALPHA_BITS: u32 = 0x0D55;
const GL_DEPTH_BITS: u32 = 0x0D56;
const GL_STENCIL_BITS: u32 = 0x0D57;
const GL_MAX_ANISOTROPY_EXT: u32 = 0x84FF;

/// On Chrome and Safari, a call to `getSupportedExtensions` returns total of 39.
pub const Extension = union(enum) {
    ANGLE_instanced_arrays: void,
    EXT_blend_minmax: void,
    EXT_clip_control: void,
    EXT_color_buffer_half_float: void,
    EXT_depth_clamp: void,
    EXT_disjoint_timer_query: void,
    EXT_float_blend: void,
    EXT_frag_depth: void,
    EXT_polygon_offset_clamp: void,
    EXT_shader_texture_lod: void,
    EXT_texture_compression_bptc: void,
    EXT_texture_compression_rgtc: void,
    EXT_texture_filter_anisotropic: void,
    EXT_texture_mirror_clamp_to_edge: void,
    EXT_sRGB: void,
    KHR_parallel_shader_compile: void,
    OES_element_index_uint: void,
    OES_fbo_render_mipmap: void,
    OES_standard_derivatives: void,
    OES_texture_float: void,
    OES_texture_float_linear: void,
    OES_texture_half_float: void,
    OES_texture_half_float_linear: void,
    OES_vertex_array_object: void,
    WEBGL_blend_func_extended: void,
    WEBGL_color_buffer_float: void,
    WEBGL_compressed_texture_astc: void,
    WEBGL_compressed_texture_etc: void,
    WEBGL_compressed_texture_etc1: void,
    WEBGL_compressed_texture_pvrtc: void,
    WEBGL_compressed_texture_s3tc: void,
    WEBGL_compressed_texture_s3tc_srgb: void,
    WEBGL_debug_renderer_info: *Type.WEBGL_debug_renderer_info,
    WEBGL_debug_shaders: void,
    WEBGL_depth_texture: void,
    WEBGL_draw_buffers: void,
    WEBGL_lose_context: *Type.WEBGL_lose_context,
    WEBGL_multi_draw: void,
    WEBGL_polygon_mode: void,

    const Kind = blk: {
        const info = @typeInfo(Extension).@"union";
        const fields = info.fields;
        const Tag = std.math.IntFittingRange(0, if (fields.len == 0) 0 else fields.len - 1);
        var names: [fields.len][:0]const u8 = undefined;
        for (fields, 0..) |field, i| {
            names[i] = field.name;
        }
        break :blk @Enum(Tag, .exhaustive, &names, &std.simd.iota(Tag, fields.len));
    };

    fn find(name: []const u8) ?Kind {
        const kvs = comptime build_kvs: {
            const T = Extension.Kind;
            const EnumKV = struct { []const u8, T };
            var kvs_array: [@typeInfo(T).@"enum".fields.len]EnumKV = undefined;
            for (@typeInfo(T).@"enum".fields, 0..) |enumField, i| {
                kvs_array[i] = .{ enumField.name, @field(T, enumField.name) };
            }
            break :build_kvs kvs_array[0..];
        };
        const Map = std.StaticStringMapWithEql(Extension.Kind, std.static_string_map.eqlAsciiIgnoreCase);
        const map = Map.initComptime(kvs);
        return map.get(name);
    }

    pub const Type = struct {
        pub const WEBGL_debug_renderer_info = struct {
            _: u8 = 0,
            pub const UNMASKED_VENDOR_WEBGL: u64 = 0x9245;
            pub const UNMASKED_RENDERER_WEBGL: u64 = 0x9246;

            pub const JsApi = struct {
                pub const bridge = js.Bridge(WEBGL_debug_renderer_info);

                pub const Meta = struct {
                    pub const name = "WEBGL_debug_renderer_info";
                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const UNMASKED_VENDOR_WEBGL = bridge.property(WEBGL_debug_renderer_info.UNMASKED_VENDOR_WEBGL, .{ .template = false, .readonly = true });
                pub const UNMASKED_RENDERER_WEBGL = bridge.property(WEBGL_debug_renderer_info.UNMASKED_RENDERER_WEBGL, .{ .template = false, .readonly = true });
            };
        };

        pub const WEBGL_lose_context = struct {
            _: u8 = 0,
            pub fn loseContext(_: *const WEBGL_lose_context) void {}
            pub fn restoreContext(_: *const WEBGL_lose_context) void {}

            pub const JsApi = struct {
                pub const bridge = js.Bridge(WEBGL_lose_context);

                pub const Meta = struct {
                    pub const name = "WEBGL_lose_context";
                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const loseContext = bridge.function(WEBGL_lose_context.loseContext, .{ .noop = true });
                pub const restoreContext = bridge.function(WEBGL_lose_context.restoreContext, .{ .noop = true });
            };
        };
    };
};

pub fn getCanvas(self: *const WebGLRenderingContext) *Canvas {
    return self._canvas;
}

/// Distinct from the 2d context seed on the same canvas (0x57454247 = "WEBG").
pub fn fingerprintSeed(self: *const WebGLRenderingContext) u64 {
    return self._fp_seed ^ 0x57454247;
}

pub fn isContextLost(_: *const WebGLRenderingContext) bool {
    return false;
}

pub fn getContextAttributes(_: *const WebGLRenderingContext, exec: *const js.Execution) !js.Object {
    const obj = exec.js.local.?.newObject();
    _ = try obj.set("alpha", true, .{});
    _ = try obj.set("antialias", true, .{});
    _ = try obj.set("depth", true, .{});
    _ = try obj.set("desynchronized", false, .{});
    _ = try obj.set("failIfMajorPerformanceCaveat", false, .{});
    _ = try obj.set("powerPreference", "default", .{});
    _ = try obj.set("premultipliedAlpha", true, .{});
    _ = try obj.set("preserveDrawingBuffer", false, .{});
    _ = try obj.set("stencil", false, .{});
    _ = try obj.set("xrCompatible", false, .{});
    return obj;
}

/// Returns string or number depending on pname (fingerprint + basic GL limits).
pub fn getParameter(_: *const WebGLRenderingContext, pname: u32, exec: *const js.Execution) !js.Value {
    const local = exec.js.local.?;
    const fp = exec.session.browser.app.config.fingerprint_profile;
    return switch (pname) {
        GL_VENDOR => local.newString(VENDOR).toValue(),
        GL_RENDERER => local.newString(RENDERER).toValue(),
        GL_VERSION => local.newString(VERSION).toValue(),
        GL_SHADING_LANGUAGE_VERSION => local.newString(SHADING_LANGUAGE_VERSION).toValue(),
        GL_UNMASKED_VENDOR => local.newString(fp.gpu_vendor).toValue(),
        GL_UNMASKED_RENDERER => local.newString(fp.gpu_renderer).toValue(),
        GL_MAX_TEXTURE_SIZE, GL_MAX_CUBE_MAP_TEXTURE_SIZE, GL_MAX_RENDERBUFFER_SIZE => try local.newNumber(@as(f64, 16384)),
        GL_MAX_VERTEX_ATTRIBS => try local.newNumber(@as(f64, 16)),
        GL_MAX_VERTEX_UNIFORM_VECTORS => try local.newNumber(@as(f64, 4096)),
        GL_MAX_VARYING_VECTORS => try local.newNumber(@as(f64, 30)),
        GL_MAX_FRAGMENT_UNIFORM_VECTORS => try local.newNumber(@as(f64, 1024)),
        GL_MAX_TEXTURE_IMAGE_UNITS, GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS => try local.newNumber(@as(f64, 16)),
        GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS => try local.newNumber(@as(f64, 16)),
        GL_RED_BITS, GL_GREEN_BITS, GL_BLUE_BITS, GL_ALPHA_BITS => try local.newNumber(@as(f64, 8)),
        GL_DEPTH_BITS => try local.newNumber(@as(f64, 24)),
        GL_STENCIL_BITS => try local.newNumber(@as(f64, 0)),
        GL_MAX_ANISOTROPY_EXT => try local.newNumber(@as(f64, 16)),
        GL_ALIASED_LINE_WIDTH_RANGE, GL_ALIASED_POINT_SIZE_RANGE => blk: {
            var arr = local.newArray(2);
            _ = try arr.set(0, @as(f64, 1), .{});
            _ = try arr.set(1, @as(f64, 1), .{});
            break :blk arr.toValue();
        },
        GL_MAX_VIEWPORT_DIMS => blk: {
            var arr = local.newArray(2);
            _ = try arr.set(0, @as(f64, 16384), .{});
            _ = try arr.set(1, @as(f64, 16384), .{});
            break :blk arr.toValue();
        },
        else => local.newString("").toValue(),
    };
}

pub fn getExtension(_: *const WebGLRenderingContext, name: []const u8, frame: *Frame) !?Extension {
    const tag = Extension.find(name) orelse return null;

    return switch (tag) {
        .WEBGL_debug_renderer_info => {
            const info = try frame._factory.create(Extension.Type.WEBGL_debug_renderer_info{});
            return .{ .WEBGL_debug_renderer_info = info };
        },
        .WEBGL_lose_context => {
            const ctx = try frame._factory.create(Extension.Type.WEBGL_lose_context{});
            return .{ .WEBGL_lose_context = ctx };
        },
        inline else => |comptime_enum| @unionInit(Extension, @tagName(comptime_enum), {}),
    };
}

pub fn getSupportedExtensions(_: *const WebGLRenderingContext) []const []const u8 {
    return std.meta.fieldNames(Extension.Kind);
}

pub fn getShaderPrecisionFormat(_: *const WebGLRenderingContext, _: u32, _: u32, exec: *const js.Execution) !js.Object {
    const obj = exec.js.local.?.newObject();
    _ = try obj.set("rangeMin", @as(i32, 127), .{});
    _ = try obj.set("rangeMax", @as(i32, 127), .{});
    _ = try obj.set("precision", @as(i32, 23), .{});
    return obj;
}

// Resource / draw no-ops — prevent TypeError cascades on partial WebGL consumers.
pub fn createBuffer(_: *const WebGLRenderingContext) void {}
pub fn createTexture(_: *const WebGLRenderingContext) void {}
pub fn createProgram(_: *const WebGLRenderingContext) void {}
pub fn createShader(_: *const WebGLRenderingContext, _: u32) void {}
pub fn createFramebuffer(_: *const WebGLRenderingContext) void {}
pub fn createRenderbuffer(_: *const WebGLRenderingContext) void {}
pub fn deleteBuffer(_: *const WebGLRenderingContext, _: ?js.Value) void {}
pub fn deleteTexture(_: *const WebGLRenderingContext, _: ?js.Value) void {}
pub fn deleteProgram(_: *const WebGLRenderingContext, _: ?js.Value) void {}
pub fn deleteShader(_: *const WebGLRenderingContext, _: ?js.Value) void {}
pub fn bindBuffer(_: *const WebGLRenderingContext, _: u32, _: ?js.Value) void {}
pub fn bindTexture(_: *const WebGLRenderingContext, _: u32, _: ?js.Value) void {}
pub fn bindFramebuffer(_: *const WebGLRenderingContext, _: u32, _: ?js.Value) void {}
pub fn bindRenderbuffer(_: *const WebGLRenderingContext, _: u32, _: ?js.Value) void {}
pub fn shaderSource(_: *const WebGLRenderingContext, _: ?js.Value, _: []const u8) void {}
pub fn compileShader(_: *const WebGLRenderingContext, _: ?js.Value) void {}
pub fn attachShader(_: *const WebGLRenderingContext, _: ?js.Value, _: ?js.Value) void {}
pub fn linkProgram(_: *const WebGLRenderingContext, _: ?js.Value) void {}
pub fn useProgram(_: *const WebGLRenderingContext, _: ?js.Value) void {}
pub fn viewport(_: *const WebGLRenderingContext, _: f64, _: f64, _: f64, _: f64) void {}
pub fn clearColor(_: *const WebGLRenderingContext, _: f64, _: f64, _: f64, _: f64) void {}
pub fn clear(_: *const WebGLRenderingContext, _: u32) void {}
pub fn enable(_: *const WebGLRenderingContext, _: u32) void {}
pub fn disable(_: *const WebGLRenderingContext, _: u32) void {}
pub fn drawArrays(_: *const WebGLRenderingContext, _: u32, _: i32, _: i32) void {}
pub fn drawElements(_: *const WebGLRenderingContext, _: u32, _: i32, _: u32, _: i32) void {}
pub fn getAttribLocation(_: *const WebGLRenderingContext, _: ?js.Value, _: []const u8) i32 {
    return -1;
}
pub fn getUniformLocation(_: *const WebGLRenderingContext, _: ?js.Value, _: []const u8) void {}
pub fn getError(_: *const WebGLRenderingContext) u32 {
    return 0; // NO_ERROR
}
pub fn getShaderParameter(_: *const WebGLRenderingContext, _: ?js.Value, _: u32) bool {
    return true;
}
pub fn getProgramParameter(_: *const WebGLRenderingContext, _: ?js.Value, _: u32) bool {
    return true;
}
pub fn getShaderInfoLog(_: *const WebGLRenderingContext, _: ?js.Value) []const u8 {
    return "";
}
pub fn getProgramInfoLog(_: *const WebGLRenderingContext, _: ?js.Value) []const u8 {
    return "";
}
pub fn pixelStorei(_: *const WebGLRenderingContext, _: u32, _: i32) void {}
pub fn texImage2D(_: *const WebGLRenderingContext, _: u32, _: i32, _: i32, _: i32, _: i32, _: i32, _: u32, _: u32, _: ?js.Value) void {}
pub fn texParameteri(_: *const WebGLRenderingContext, _: u32, _: u32, _: i32) void {}
pub fn activeTexture(_: *const WebGLRenderingContext, _: u32) void {}
pub fn bufferData(_: *const WebGLRenderingContext, _: u32, _: ?js.Value, _: u32) void {}
pub fn enableVertexAttribArray(_: *const WebGLRenderingContext, _: u32) void {}
pub fn vertexAttribPointer(_: *const WebGLRenderingContext, _: u32, _: i32, _: u32, _: bool, _: i32, _: i32) void {}
pub fn uniform1f(_: *const WebGLRenderingContext, _: ?js.Value, _: f64) void {}
pub fn uniform1i(_: *const WebGLRenderingContext, _: ?js.Value, _: i32) void {}
pub fn uniform2f(_: *const WebGLRenderingContext, _: ?js.Value, _: f64, _: f64) void {}
pub fn uniformMatrix4fv(_: *const WebGLRenderingContext, _: ?js.Value, _: bool, _: ?js.Value) void {}
pub fn scissor(_: *const WebGLRenderingContext, _: i32, _: i32, _: i32, _: i32) void {}
pub fn blendFunc(_: *const WebGLRenderingContext, _: u32, _: u32) void {}
pub fn depthFunc(_: *const WebGLRenderingContext, _: u32) void {}
pub fn cullFace(_: *const WebGLRenderingContext, _: u32) void {}
pub fn frontFace(_: *const WebGLRenderingContext, _: u32) void {}
/// Fingerprint probes draw a scene then hash readPixels — an all-zero buffer is
/// a louder headless tell than a wrong GPU string. Fill it with the same seeded
/// generator the 2d canvas and toDataURL use.
/// ponytail: byte destinations only (UNSIGNED_BYTE, the format every probe
/// uses); handle float/half-float views when something actually reads them.
pub fn readPixels(self: *const WebGLRenderingContext, x: i32, y: i32, width: i32, height: i32, _: u32, _: u32, dest: ?js.Value) void {
    const value = dest orelse return;
    if (!value.isUint8Array() and !value.isUint8ClampedArray()) return;
    const pixels = value.local.jsValueToZig([]u8, value) catch return;

    var seed = self.fingerprintSeed();
    inline for (.{ x, y, width, height }) |v| {
        seed = (seed ^ @as(u64, @bitCast(@as(i64, v)))) *% 0x100000001b3;
    }
    Canvas.fillFingerprintPixels(pixels, seed, if (width > 0) @intCast(width) else 1);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebGLRenderingContext);

    pub const Meta = struct {
        pub const name = "WebGLRenderingContext";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(WebGLRenderingContext.getCanvas, null, .{});
    pub const drawingBufferWidth = bridge.property(300, .{ .template = false, .readonly = true });
    pub const drawingBufferHeight = bridge.property(150, .{ .template = false, .readonly = true });

    // Common GLenum constants as instance properties (Chrome exposes these)
    pub const VENDOR = bridge.property(GL_VENDOR, .{ .template = false, .readonly = true });
    pub const RENDERER = bridge.property(GL_RENDERER, .{ .template = false, .readonly = true });
    pub const VERSION = bridge.property(GL_VERSION, .{ .template = false, .readonly = true });
    pub const SHADING_LANGUAGE_VERSION = bridge.property(GL_SHADING_LANGUAGE_VERSION, .{ .template = false, .readonly = true });
    pub const MAX_TEXTURE_SIZE = bridge.property(GL_MAX_TEXTURE_SIZE, .{ .template = false, .readonly = true });
    pub const NO_ERROR = bridge.property(@as(u32, 0), .{ .template = false, .readonly = true });
    pub const ARRAY_BUFFER = bridge.property(@as(u32, 0x8892), .{ .template = false, .readonly = true });
    pub const ELEMENT_ARRAY_BUFFER = bridge.property(@as(u32, 0x8893), .{ .template = false, .readonly = true });
    pub const TEXTURE_2D = bridge.property(@as(u32, 0x0DE1), .{ .template = false, .readonly = true });
    pub const FLOAT = bridge.property(@as(u32, 0x1406), .{ .template = false, .readonly = true });
    pub const UNSIGNED_BYTE = bridge.property(@as(u32, 0x1401), .{ .template = false, .readonly = true });
    pub const TRIANGLES = bridge.property(@as(u32, 0x0004), .{ .template = false, .readonly = true });
    pub const COLOR_BUFFER_BIT = bridge.property(@as(u32, 0x00004000), .{ .template = false, .readonly = true });
    pub const DEPTH_BUFFER_BIT = bridge.property(@as(u32, 0x00000100), .{ .template = false, .readonly = true });
    pub const FRAGMENT_SHADER = bridge.property(@as(u32, 0x8B30), .{ .template = false, .readonly = true });
    pub const VERTEX_SHADER = bridge.property(@as(u32, 0x8B31), .{ .template = false, .readonly = true });
    pub const COMPILE_STATUS = bridge.property(@as(u32, 0x8B81), .{ .template = false, .readonly = true });
    pub const LINK_STATUS = bridge.property(@as(u32, 0x8B82), .{ .template = false, .readonly = true });

    pub const getParameter = bridge.function(WebGLRenderingContext.getParameter, .{});
    pub const getExtension = bridge.function(WebGLRenderingContext.getExtension, .{});
    pub const getSupportedExtensions = bridge.function(WebGLRenderingContext.getSupportedExtensions, .{});
    pub const getContextAttributes = bridge.function(WebGLRenderingContext.getContextAttributes, .{});
    pub const getShaderPrecisionFormat = bridge.function(WebGLRenderingContext.getShaderPrecisionFormat, .{});
    pub const isContextLost = bridge.function(WebGLRenderingContext.isContextLost, .{});

    pub const createBuffer = bridge.function(WebGLRenderingContext.createBuffer, .{ .noop = true });
    pub const createTexture = bridge.function(WebGLRenderingContext.createTexture, .{ .noop = true });
    pub const createProgram = bridge.function(WebGLRenderingContext.createProgram, .{ .noop = true });
    pub const createShader = bridge.function(WebGLRenderingContext.createShader, .{ .noop = true });
    pub const createFramebuffer = bridge.function(WebGLRenderingContext.createFramebuffer, .{ .noop = true });
    pub const createRenderbuffer = bridge.function(WebGLRenderingContext.createRenderbuffer, .{ .noop = true });
    pub const deleteBuffer = bridge.function(WebGLRenderingContext.deleteBuffer, .{ .noop = true });
    pub const deleteTexture = bridge.function(WebGLRenderingContext.deleteTexture, .{ .noop = true });
    pub const deleteProgram = bridge.function(WebGLRenderingContext.deleteProgram, .{ .noop = true });
    pub const deleteShader = bridge.function(WebGLRenderingContext.deleteShader, .{ .noop = true });
    pub const bindBuffer = bridge.function(WebGLRenderingContext.bindBuffer, .{ .noop = true });
    pub const bindTexture = bridge.function(WebGLRenderingContext.bindTexture, .{ .noop = true });
    pub const bindFramebuffer = bridge.function(WebGLRenderingContext.bindFramebuffer, .{ .noop = true });
    pub const bindRenderbuffer = bridge.function(WebGLRenderingContext.bindRenderbuffer, .{ .noop = true });
    pub const shaderSource = bridge.function(WebGLRenderingContext.shaderSource, .{ .noop = true });
    pub const compileShader = bridge.function(WebGLRenderingContext.compileShader, .{ .noop = true });
    pub const attachShader = bridge.function(WebGLRenderingContext.attachShader, .{ .noop = true });
    pub const linkProgram = bridge.function(WebGLRenderingContext.linkProgram, .{ .noop = true });
    pub const useProgram = bridge.function(WebGLRenderingContext.useProgram, .{ .noop = true });
    pub const viewport = bridge.function(WebGLRenderingContext.viewport, .{ .noop = true });
    pub const clearColor = bridge.function(WebGLRenderingContext.clearColor, .{ .noop = true });
    pub const clear = bridge.function(WebGLRenderingContext.clear, .{ .noop = true });
    pub const enable = bridge.function(WebGLRenderingContext.enable, .{ .noop = true });
    pub const disable = bridge.function(WebGLRenderingContext.disable, .{ .noop = true });
    pub const drawArrays = bridge.function(WebGLRenderingContext.drawArrays, .{ .noop = true });
    pub const drawElements = bridge.function(WebGLRenderingContext.drawElements, .{ .noop = true });
    pub const getAttribLocation = bridge.function(WebGLRenderingContext.getAttribLocation, .{});
    pub const getUniformLocation = bridge.function(WebGLRenderingContext.getUniformLocation, .{ .noop = true });
    pub const getError = bridge.function(WebGLRenderingContext.getError, .{});
    pub const getShaderParameter = bridge.function(WebGLRenderingContext.getShaderParameter, .{});
    pub const getProgramParameter = bridge.function(WebGLRenderingContext.getProgramParameter, .{});
    pub const getShaderInfoLog = bridge.function(WebGLRenderingContext.getShaderInfoLog, .{});
    pub const getProgramInfoLog = bridge.function(WebGLRenderingContext.getProgramInfoLog, .{});
    pub const pixelStorei = bridge.function(WebGLRenderingContext.pixelStorei, .{ .noop = true });
    pub const texImage2D = bridge.function(WebGLRenderingContext.texImage2D, .{ .noop = true });
    pub const texParameteri = bridge.function(WebGLRenderingContext.texParameteri, .{ .noop = true });
    pub const activeTexture = bridge.function(WebGLRenderingContext.activeTexture, .{ .noop = true });
    pub const bufferData = bridge.function(WebGLRenderingContext.bufferData, .{ .noop = true });
    pub const enableVertexAttribArray = bridge.function(WebGLRenderingContext.enableVertexAttribArray, .{ .noop = true });
    pub const vertexAttribPointer = bridge.function(WebGLRenderingContext.vertexAttribPointer, .{ .noop = true });
    pub const uniform1f = bridge.function(WebGLRenderingContext.uniform1f, .{ .noop = true });
    pub const uniform1i = bridge.function(WebGLRenderingContext.uniform1i, .{ .noop = true });
    pub const uniform2f = bridge.function(WebGLRenderingContext.uniform2f, .{ .noop = true });
    pub const uniformMatrix4fv = bridge.function(WebGLRenderingContext.uniformMatrix4fv, .{ .noop = true });
    pub const scissor = bridge.function(WebGLRenderingContext.scissor, .{ .noop = true });
    pub const blendFunc = bridge.function(WebGLRenderingContext.blendFunc, .{ .noop = true });
    pub const depthFunc = bridge.function(WebGLRenderingContext.depthFunc, .{ .noop = true });
    pub const cullFace = bridge.function(WebGLRenderingContext.cullFace, .{ .noop = true });
    pub const frontFace = bridge.function(WebGLRenderingContext.frontFace, .{ .noop = true });
    pub const readPixels = bridge.function(WebGLRenderingContext.readPixels, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGLRenderingContext" {
    try testing.htmlRunner("canvas/webgl_rendering_context.html", .{});
}
