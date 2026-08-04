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
const builtin = @import("builtin");

const Config = @import("../../Config.zig");
const js = @import("../js/js.zig");
const Execution = js.Execution;

const Brand = Config.HttpHeaders.Brand;

_pad: bool = false,

pub fn getBrands(_: *const @This(), exec: *const Execution) !js.Value {
    const local = exec.js.local.?;
    const brands = try local.zigValueToJs(brandList(exec), .{});
    return local.freeze(brands);
}

pub fn getMobile(_: *const @This()) bool {
    return false;
}

pub fn getPlatform(_: *const @This(), exec: *const Execution) []const u8 {
    return uaPlatform(exec);
}

pub fn toJSON(_: *const @This(), exec: *const Execution) struct {
    brands: []const Brand,
    mobile: bool,
    platform: []const u8,
} {
    return .{
        .mobile = false,
        .brands = brandList(exec),
        .platform = uaPlatform(exec),
    };
}

pub fn getHighEntropyValues(_: *const @This(), hints: []const []const u8, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const values = local.newObject();
    _ = try values.set("brands", brandList(exec), .{});
    _ = try values.set("mobile", false, .{});
    _ = try values.set("platform", uaPlatform(exec), .{});

    for (hints) |hint| {
        if (std.mem.eql(u8, hint, "architecture")) {
            _ = try values.set(hint, uaArchitecture(), .{});
        } else if (std.mem.eql(u8, hint, "bitness")) {
            _ = try values.set(hint, uaBitness(), .{});
        } else if (std.mem.eql(u8, hint, "model")) {
            _ = try values.set(hint, "", .{});
        } else if (std.mem.eql(u8, hint, "platformVersion")) {
            _ = try values.set(hint, platformVersion(exec), .{});
        } else if (std.mem.eql(u8, hint, "uaFullVersion")) {
            _ = try values.set(hint, fullVersion(exec), .{});
        } else if (std.mem.eql(u8, hint, "fullVersionList")) {
            _ = try values.set(hint, fullBrandList(exec), .{});
        } else if (std.mem.eql(u8, hint, "wow64")) {
            _ = try values.set(hint, false, .{});
        } else if (std.mem.eql(u8, hint, "formFactors")) {
            _ = try values.set(hint, [_][]const u8{}, .{});
        }
    }

    return local.resolvePromise(values);
}

fn stealth(exec: *const Execution) bool {
    return exec.session.browser.app.config.http_headers.stealth;
}

// Under --stealth the brands already carry the Chrome version, so the same
// list doubles as the full-version list.
fn fullBrandList(exec: *const Execution) []const Brand {
    return if (stealth(exec)) brandList(exec) else &Config.HttpHeaders.full_brands;
}

fn fullVersion(exec: *const Execution) []const u8 {
    return if (stealth(exec)) Config.HttpHeaders.stealth_ua_full_version else Config.HttpHeaders.product_version;
}

fn platformVersion(exec: *const Execution) []const u8 {
    if (!stealth(exec)) return "";
    return switch (exec.session.browser.app.config.fingerprint_profile.platform) {
        .windows => "15.0.0",
        .macos => "10.15.7",
        .linux => "6.6.0",
    };
}

fn brandList(exec: *const Execution) []const Brand {
    return exec.session.browser.app.config.http_headers.brand_list;
}

fn uaPlatform(exec: *const Execution) []const u8 {
    const fp = exec.session.browser.app.config.fingerprint_profile;
    if (fp.seed != 0) {
        return fp.platform.uaChPlatform();
    }
    return switch (builtin.os.tag) {
        .macos => "macOS",
        .windows => "Windows",
        .linux => "Linux",
        .freebsd => "FreeBSD",
        else => "Unknown",
    };
}

fn uaArchitecture() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => "x86",
        .aarch64, .aarch64_be, .arm, .armeb => "arm",
        else => "",
    };
}

fn uaBitness() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64, .aarch64, .aarch64_be, .powerpc64, .powerpc64le, .riscv64 => "64",
        else => "32",
    };
}

const Self = @This();

pub const JsApi = struct {
    pub const bridge = js.Bridge(Self);

    pub const Meta = struct {
        pub const name = "NavigatorUAData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const brands = bridge.accessor(getBrands, null, .{ .cache = .{ .private = "navigator_array" } });
    pub const mobile = bridge.accessor(getMobile, null, .{});
    pub const platform = bridge.accessor(getPlatform, null, .{});
    pub const toJSON = bridge.function(toJSONFn, .{});
    pub const getHighEntropyValues = bridge.function(getHighEntropyValuesFn, .{});
};

// Aliases avoid JsApi field names shadowing the free functions.
const toJSONFn = toJSON;
const getHighEntropyValuesFn = getHighEntropyValues;
