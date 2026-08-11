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
const builtin = @import("builtin");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Execution = js.Execution;

const plugin_mod = @import("PluginArray.zig");
const PluginArray = plugin_mod.PluginArray;
const MimeTypeArray = plugin_mod.MimeTypeArray;
const Permissions = @import("Permissions.zig");
const StorageManager = @import("StorageManager.zig");
const NavigatorUAData = @import("NavigatorUAData.zig");
const ModelContext = @import("ModelContext.zig");
const MediaDevices = @import("MediaDevices.zig");
const device = @import("device.zig");

const Navigator = @This();
_pad: bool = false,
_plugins: PluginArray = .{},
_mime_types: MimeTypeArray = .{},
_permissions: Permissions = .{},
_storage: StorageManager = .{},
_ua_data: NavigatorUAData = .{},
_media_devices: MediaDevices = .{},
_battery: device.BatteryManager = .{},
_connection: device.NetworkInformation = .{},

pub const init: Navigator = .{};

pub fn getUserAgent(_: *const Navigator, exec: *const Execution) []const u8 {
    return exec.session.browser.http_client.getUserAgent();
}

/// `--locale`, split into the full tag plus its primary subtag, the way Chrome
/// reports it ("fr-FR" -> ["fr-FR", "fr"]). A tag with no region yields the
/// same value twice, which is what Chrome shows for a region-less locale.
/// Chrome freezes the array, so we do too.
pub fn getLanguages(self: *const Navigator, exec: *const Execution) !js.Value {
    const tag = self.getLanguage(exec);
    const end = std.mem.indexOfScalar(u8, tag, '-') orelse tag.len;
    const local = exec.js.local.?;
    const languages = try local.zigValueToJs([2][]const u8{ tag, tag[0..end] }, .{});
    return local.freeze(languages);
}

pub fn getDoNotTrack(_: *const Navigator) ?[]const u8 {
    return null;
}

pub fn getAppName(_: *const Navigator) []const u8 {
    return "Netscape";
}

pub fn getAppCodeName(_: *const Navigator) []const u8 {
    return "Mozilla";
}

pub fn getAppVersion(self: *const Navigator, exec: *const Execution) ![]const u8 {
    const user_agent = getUserAgent(self, exec);
    const lightpanda_prefix = "Lightpanda/";
    if (std.mem.startsWith(u8, user_agent, lightpanda_prefix)) {
        const version = user_agent[lightpanda_prefix.len..];
        const end = std.mem.indexOfScalar(u8, version, ' ') orelse version.len;
        return version[0..end];
    }

    const prefix = "Mozilla/";
    if (!std.mem.startsWith(u8, user_agent, "Mozilla/5.0 (")) {
        return "";
    }
    return user_agent[prefix.len..];
}

pub fn getLanguage(_: *const Navigator, exec: *const Execution) []const u8 {
    return exec.session.browser.app.config.locale();
}

pub fn getOnLine(_: *const Navigator) bool {
    return true;
}

pub fn getCookieEnabled(_: *const Navigator) bool {
    return true;
}

pub fn getHardwareConcurrency(_: *const Navigator, exec: *const Execution) u32 {
    const config = exec.session.browser.app.config;
    if (config.fingerprint_profile.seed != 0) {
        return config.fingerprint_profile.hardware_concurrency;
    }
    return @intCast(std.Thread.getCpuCount() catch 1);
}

pub fn getDeviceMemory(_: *const Navigator, exec: *const Execution) f64 {
    return exec.session.browser.app.config.fingerprint_profile.device_memory_gb;
}

pub fn getMaxTouchPoints(_: *const Navigator) u32 {
    return 0;
}

pub fn getVendor(_: *const Navigator, exec: *const Execution) []const u8 {
    // Chrome reports "Google Inc."; an empty vendor next to a Chrome UA is a
    // headless tell, so it tracks the stealth identity.
    return if (exec.session.browser.app.config.http_headers.stealth) "Google Inc." else "";
}

pub fn getProduct(_: *const Navigator) []const u8 {
    return "Gecko";
}

// Chrome only sets this when a WebDriver client is attached. We deliberately
// always report false, even while a WebDriver session is driving the browser:
// reporting true is the single loudest automation signal a page can read.
pub fn getWebdriver(_: *const Navigator) bool {
    return false;
}

// Default to false: per https://w3c.github.io/gpc/#javascript-property the
// signal reflects an explicit user preference, and none is configured here.
// Firefox defaults to false; Chrome doesn't expose the property. Returning
// true made GPC-compliant consent managers treat every page load as "reject
// tracking" and skip their consent UI entirely.
pub fn getGlobalPrivacyControl(_: *const Navigator) bool {
    return false;
}

pub fn getPlatform(_: *const Navigator, exec: *const Execution) []const u8 {
    const fp = exec.session.browser.app.config.fingerprint_profile;
    if (fp.seed != 0) {
        return fp.navigatorPlatform();
    }
    return switch (builtin.os.tag) {
        .macos => "MacIntel",
        .windows => "Win32",
        .linux => "Linux x86_64",
        .freebsd => "FreeBSD",
        else => "Unknown",
    };
}

/// Returns whether Java is enabled (always false)
pub fn javaEnabled(_: *const Navigator) bool {
    return false;
}

/// Noop, signal that the data was successfully queued
pub fn sendBeacon(_: *const Navigator, url: js.Value, data: ?js.Value) bool {
    _ = url;
    _ = data;
    return true;
}

pub fn getPlugins(self: *Navigator) *PluginArray {
    return &self._plugins;
}

pub fn getMimeTypes(self: *Navigator) *MimeTypeArray {
    return &self._mime_types;
}

pub fn getPermissions(self: *Navigator) *Permissions {
    return &self._permissions;
}

pub fn getStorage(self: *Navigator) *StorageManager {
    return &self._storage;
}

pub fn getUserAgentData(self: *Navigator) *NavigatorUAData {
    return &self._ua_data;
}

/// The PDF plugin array already claims a viewer; reporting false here would
/// contradict it, and mismatched pairs are exactly what scanners look for.
pub fn getPdfViewerEnabled(_: *const Navigator) bool {
    return true;
}

pub fn getMediaDevices(self: *Navigator) *MediaDevices {
    return &self._media_devices;
}

pub fn getConnection(self: *Navigator) *device.NetworkInformation {
    return &self._connection;
}

pub fn getBattery(self: *Navigator, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(&self._battery);
}

/// Chrome hands out four fixed slots, all null when nothing is plugged in.
pub fn getGamepads(_: *const Navigator) [4]?u8 {
    return .{ null, null, null, null };
}

/// Web Share. Chrome desktop ships both members, and their absence is a
/// headless tell in its own right (CreepJS counts `noWebShare`).
///
/// `share` rejects rather than pretending to have opened a share sheet: with
/// no transient user activation that is exactly what Chrome does, so callers
/// take the same fallback branch they take on a real desktop.
pub fn canShare(_: *const Navigator, data: ?js.Value) bool {
    const value = data orelse return false;
    return value.isObject();
}

pub fn share(self: *const Navigator, data: ?js.Value, exec: *const Execution) js.Promise {
    const local = exec.js.local.?;
    if (self.canShare(data) == false) {
        return local.rejectPromise(.{ .type_error = "Invalid share data" });
    }
    return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotAllowedError } });
}

pub fn getModelContext(_: *const Navigator, frame: *Frame) *ModelContext {
    return &frame.window._model_context;
}

pub fn registerProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}
pub fn unregisterProtocolHandler(_: *const Navigator, scheme: []const u8, url: [:0]const u8, frame: *const Frame) !void {
    try validateProtocolHandlerScheme(scheme);
    try validateProtocolHandlerURL(url, frame);
}

fn validateProtocolHandlerScheme(scheme: []const u8) !void {
    const allowed = std.StaticStringMap(void).initComptime(.{
        .{ "bitcoin", {} },
        .{ "cabal", {} },
        .{ "dat", {} },
        .{ "did", {} },
        .{ "dweb", {} },
        .{ "ethereum", .{} },
        .{ "ftp", {} },
        .{ "ftps", {} },
        .{ "geo", {} },
        .{ "im", {} },
        .{ "ipfs", {} },
        .{ "ipns", .{} },
        .{ "irc", {} },
        .{ "ircs", {} },
        .{ "hyper", {} },
        .{ "magnet", {} },
        .{ "mailto", {} },
        .{ "matrix", {} },
        .{ "mms", {} },
        .{ "news", {} },
        .{ "nntp", {} },
        .{ "openpgp4fpr", {} },
        .{ "sftp", {} },
        .{ "sip", {} },
        .{ "sms", {} },
        .{ "smsto", {} },
        .{ "ssb", {} },
        .{ "ssh", {} },
        .{ "tel", {} },
        .{ "urn", {} },
        .{ "webcal", {} },
        .{ "wtai", {} },
        .{ "xmpp", {} },
    });
    if (allowed.has(scheme)) {
        return;
    }

    if (scheme.len < 5 or !std.mem.startsWith(u8, scheme, "web+")) {
        return error.SecurityError;
    }
    for (scheme[4..]) |b| {
        if (std.ascii.isLower(b) == false) {
            return error.SecurityError;
        }
    }
}

fn validateProtocolHandlerURL(url: [:0]const u8, frame: *const Frame) !void {
    if (std.mem.indexOf(u8, url, "%s") == null) {
        return error.SyntaxError;
    }
    if (frame.isSameOrigin(url) == false) {
        return error.SyntaxError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Navigator);

    pub const Meta = struct {
        pub const name = "Navigator";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const userAgent = bridge.accessor(Navigator.getUserAgent, null, .{});
    pub const appName = bridge.accessor(Navigator.getAppName, null, .{});
    pub const appCodeName = bridge.accessor(Navigator.getAppCodeName, null, .{});
    pub const appVersion = bridge.accessor(Navigator.getAppVersion, null, .{});
    pub const platform = bridge.accessor(Navigator.getPlatform, null, .{});
    pub const language = bridge.accessor(Navigator.getLanguage, null, .{});
    pub const languages = bridge.accessor(Navigator.getLanguages, null, .{ .cache = .{ .private = "navigator_array" } });
    pub const onLine = bridge.accessor(Navigator.getOnLine, null, .{});
    pub const cookieEnabled = bridge.accessor(Navigator.getCookieEnabled, null, .{});
    pub const hardwareConcurrency = bridge.accessor(Navigator.getHardwareConcurrency, null, .{});
    pub const deviceMemory = bridge.accessor(Navigator.getDeviceMemory, null, .{});
    pub const maxTouchPoints = bridge.accessor(Navigator.getMaxTouchPoints, null, .{});
    pub const vendor = bridge.accessor(Navigator.getVendor, null, .{ .exposed = .window });
    pub const product = bridge.accessor(Navigator.getProduct, null, .{});
    pub const webdriver = bridge.accessor(Navigator.getWebdriver, null, .{ .exposed = .window });
    pub const doNotTrack = bridge.accessor(Navigator.getDoNotTrack, null, .{});
    pub const globalPrivacyControl = bridge.accessor(Navigator.getGlobalPrivacyControl, null, .{});

    pub const javaEnabled = bridge.function(Navigator.javaEnabled, .{ .exposed = .window });
    pub const share = bridge.function(Navigator.share, .{ .exposed = .window });
    pub const canShare = bridge.function(Navigator.canShare, .{ .exposed = .window });
    // Not `.noop`: that returns undefined, and callers branch on the boolean
    // (`if (!navigator.sendBeacon(...)) fallbackToSyncXHR()`), so a missing
    // return value sends them down a fallback path for a beacon that was in
    // fact accepted.
    pub const sendBeacon = bridge.function(Navigator.sendBeacon, .{ .exposed = .window });
    pub const permissions = bridge.accessor(Navigator.getPermissions, null, .{});
    pub const storage = bridge.accessor(Navigator.getStorage, null, .{});
    pub const userAgentData = bridge.accessor(Navigator.getUserAgentData, null, .{});

    // window only
    pub const pdfViewerEnabled = bridge.accessor(Navigator.getPdfViewerEnabled, null, .{ .exposed = .window });
    pub const mediaDevices = bridge.accessor(Navigator.getMediaDevices, null, .{ .exposed = .window });
    pub const connection = bridge.accessor(Navigator.getConnection, null, .{ .exposed = .window });
    pub const getBattery = bridge.function(Navigator.getBattery, .{ .exposed = .window });
    pub const getGamepads = bridge.function(Navigator.getGamepads, .{ .exposed = .window });
    pub const plugins = bridge.accessor(Navigator.getPlugins, null, .{ .exposed = .window });
    pub const mimeTypes = bridge.accessor(Navigator.getMimeTypes, null, .{ .exposed = .window });
    pub const modelContext = bridge.accessor(Navigator.getModelContext, null, .{ .exposed = .window });
    pub const registerProtocolHandler = bridge.function(Navigator.registerProtocolHandler, .{ .exposed = .window });
    pub const unregisterProtocolHandler = bridge.function(Navigator.unregisterProtocolHandler, .{ .exposed = .window });
};

const testing = @import("../../testing.zig");
test "WebApi: Navigator" {
    try testing.htmlRunner("navigator", .{});
}
