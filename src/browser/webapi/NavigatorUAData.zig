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

const builtin = @import("builtin");

const Config = @import("../../Config.zig");
const js = @import("../js/js.zig");
const Execution = js.Execution;

const Brand = struct {
    brand: []const u8,
    version: []const u8,
};

_pad: bool = false,

pub fn getBrands(_: *const @This(), exec: *const Execution) []const Brand {
    return brandList(exec);
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
    _ = hints;

    const stealth = exec.session.browser.app.config.http_headers.stealth;
    const brands = brandList(exec);
    const full_ver: []const u8 = if (stealth)
        Config.HttpHeaders.stealth_ua_full_version
    else
        "1.0.0.0";
    const platform_version: []const u8 = if (stealth)
        "15.0.0"
    else
        "";

    return exec.js.local.?.resolvePromise(.{
        .brands = brands,
        .mobile = false,
        .platform = uaPlatform(exec),
        .architecture = uaArchitecture(),
        .bitness = uaBitness(),
        .model = "",
        .platformVersion = platform_version,
        .uaFullVersion = full_ver,
        .fullVersionList = brands,
        .wow64 = false,
        .formFactor = [_][]const u8{"Desktop"},
    });
}

fn brandList(exec: *const Execution) []const Brand {
    return stableBrandSlice(exec.session.browser.app.config.http_headers.stealth);
}

fn stableBrandSlice(stealth: bool) []const Brand {
    const S = struct {
        var default_done = false;
        var stealth_done = false;
        var default_brands: [Config.HttpHeaders.brands_default.len]Brand = undefined;
        var stealth_brands: [Config.HttpHeaders.brands_stealth.len]Brand = undefined;
    };
    if (stealth) {
        if (!S.stealth_done) {
            for (Config.HttpHeaders.brands_stealth, 0..) |b, i| {
                S.stealth_brands[i] = .{ .brand = b.brand, .version = b.version };
            }
            S.stealth_done = true;
        }
        return S.stealth_brands[0..];
    }
    if (!S.default_done) {
        for (Config.HttpHeaders.brands_default, 0..) |b, i| {
            S.default_brands[i] = .{ .brand = b.brand, .version = b.version };
        }
        S.default_done = true;
    }
    return S.default_brands[0..];
}

fn uaPlatform(exec: *const Execution) []const u8 {
    const cfg = exec.session.browser.app.config;
    const fp = cfg.fingerprint_profile;
    // CloakBrowser-style: seed/stealth profile drives UA-CH platform.
    if (fp.seed != 0 or cfg.stealth()) {
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

    pub const brands = bridge.accessor(getBrands, null, .{});
    pub const mobile = bridge.accessor(getMobile, null, .{});
    pub const platform = bridge.accessor(getPlatform, null, .{});
    pub const toJSON = bridge.function(toJSONFn, .{});
    pub const getHighEntropyValues = bridge.function(getHighEntropyValuesFn, .{});
};

// Aliases avoid JsApi field names shadowing the free functions.
const toJSONFn = toJSON;
const getHighEntropyValuesFn = getHighEntropyValues;
