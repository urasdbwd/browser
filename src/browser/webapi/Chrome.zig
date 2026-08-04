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

//! Minimal `window.chrome` surface for Chrome-targeting bot scanners
//! (sannysoft, CreepJS). Shape matches Chromium's chrome.runtime presence
//! checks without implementing extension messaging.

const lp = @import("lightpanda");

const js = @import("../js/js.zig");

pub fn registerTypes() []const type {
    return &.{ Chrome, ChromeRuntime, ChromeApp };
}

const Chrome = @This();

_runtime: ChromeRuntime = .{},
_app: ChromeApp = .{},

pub fn getRuntime(self: *Chrome) *ChromeRuntime {
    return &self._runtime;
}

pub fn getApp(self: *Chrome) *ChromeApp {
    return &self._app;
}

/// Navigation timing as Chrome's legacy `chrome.*` APIs report it: wall-clock
/// epoch for the origin, milliseconds-since-origin for the milestones.
const Timing = struct {
    nav_start_ms: f64,
    page_t: f64,
    dcl_t: f64,
    load_t: f64,

    fn get(exec: *const js.Execution) Timing {
        const perf = exec.performance();
        const page_t = perf.now();
        const epoch_ms: f64 = @floatFromInt(lp.datetime.milliTimestamp(.real));
        // Milestones are 0 until they fire; clamp to "now" so the values stay
        // monotone and never land in the future.
        const dcl = if (perf._dom_content_loaded > 0) perf._dom_content_loaded else page_t;
        const load = if (perf._load_event_end > 0) perf._load_event_end else dcl;
        return .{
            .nav_start_ms = epoch_ms - page_t,
            .page_t = page_t,
            .dcl_t = dcl,
            .load_t = load,
        };
    }

    fn epochSeconds(self: *const Timing, offset_ms: f64) f64 {
        return (self.nav_start_ms + offset_ms) / 1000.0;
    }
};

pub fn csi(_: *const Chrome, exec: *const js.Execution) !js.Object {
    const t: Timing = .get(exec);
    const obj = exec.js.local.?.newObject();
    _ = try obj.set("startE", @floor(t.nav_start_ms), .{});
    _ = try obj.set("onloadT", @floor(t.nav_start_ms + t.load_t), .{});
    _ = try obj.set("pageT", t.page_t, .{});
    _ = try obj.set("tran", @as(i32, 15), .{});
    return obj;
}

pub fn loadTimes(_: *const Chrome, exec: *const js.Execution) !js.Object {
    const t: Timing = .get(exec);
    const obj = exec.js.local.?.newObject();
    // ponytail: connect/commit/paint aren't recorded separately, so they're
    // fractions of the DOMContentLoaded offset. Swap for real resource timing
    // if a scanner ever checks the individual gaps rather than "non-zero and
    // ordered".
    _ = try obj.set("requestTime", t.epochSeconds(0), .{});
    _ = try obj.set("startLoadTime", t.epochSeconds(0), .{});
    _ = try obj.set("commitLoadTime", t.epochSeconds(t.dcl_t * 0.25), .{});
    _ = try obj.set("finishDocumentLoadTime", t.epochSeconds(t.dcl_t), .{});
    _ = try obj.set("finishLoadTime", t.epochSeconds(t.load_t), .{});
    _ = try obj.set("firstPaintTime", t.epochSeconds(t.dcl_t * 0.9), .{});
    _ = try obj.set("firstPaintAfterLoadTime", @as(f64, 0), .{});
    _ = try obj.set("navigationType", "Other", .{});
    _ = try obj.set("wasFetchedViaSpdy", false, .{});
    _ = try obj.set("wasNpnNegotiated", false, .{});
    _ = try obj.set("npnNegotiatedProtocol", "", .{});
    _ = try obj.set("wasAlternateProtocolAvailable", false, .{});
    _ = try obj.set("connectionInfo", "http/1.1", .{});
    return obj;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Chrome);

    pub const Meta = struct {
        pub const name = "Chrome";
        // Real Chrome has no `window.Chrome` interface object.
        pub const no_interface_object = true;
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const runtime = bridge.accessor(Chrome.getRuntime, null, .{});
    pub const app = bridge.accessor(Chrome.getApp, null, .{});
    pub const csi = bridge.function(Chrome.csi, .{});
    pub const loadTimes = bridge.function(Chrome.loadTimes, .{});
};

pub const ChromeRuntime = struct {
    _pad: bool = false,

    pub fn connect(_: *const ChromeRuntime) void {}
    pub fn sendMessage(_: *const ChromeRuntime) void {}

    pub fn getId(_: *const ChromeRuntime) void {
        // Chrome exposes `chrome.runtime.id` as undefined outside extensions.
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ChromeRuntime);
        pub const Meta = struct {
            pub const name = "ChromeRuntime";
            pub const no_interface_object = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
        // chrome.runtime.id is undefined outside extensions — omit as data prop;
        // scanners only check that `chrome.runtime` exists as an object.
        pub const connect = bridge.function(ChromeRuntime.connect, .{ .noop = true });
        pub const sendMessage = bridge.function(ChromeRuntime.sendMessage, .{ .noop = true });
    };
};

pub const ChromeApp = struct {
    _pad: bool = false,

    pub fn getIsInstalled(_: *const ChromeApp) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ChromeApp);
        pub const Meta = struct {
            pub const name = "ChromeApp";
            pub const no_interface_object = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
        pub const isInstalled = bridge.accessor(ChromeApp.getIsInstalled, null, .{});
    };
};
