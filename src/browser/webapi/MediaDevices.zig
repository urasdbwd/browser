// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! `navigator.mediaDevices`. A missing mediaDevices is itself a headless tell,
//! but a *populated* one would have to invent device ids. This mirrors what a
//! real Chrome reports before any camera/microphone permission is granted: one
//! placeholder entry per device kind, with empty deviceId/label/groupId. Which
//! kinds exist is seeded, so different fingerprints look like different
//! machines without fabricating identifiers.

const js = @import("../js/js.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ MediaDevices, MediaDeviceInfo };
}

const MediaDevices = @This();

// Padding to avoid zero-size struct pointer collisions.
_pad: bool = false,

pub fn enumerateDevices(_: *const MediaDevices, exec: *const Execution) !js.Promise {
    const seed = exec.session.browser.app.config.fingerprint_profile.noise_seed;
    // ~2 in 3 desktop profiles have a webcam.
    const kinds: []const []const u8 = if (seed % 3 != 0)
        &.{ "audioinput", "videoinput", "audiooutput" }
    else
        &.{ "audioinput", "audiooutput" };

    const devices = try exec.arena.alloc(*MediaDeviceInfo, kinds.len);
    for (kinds, devices) |kind, *slot| {
        slot.* = try exec._factory.create(MediaDeviceInfo{ ._kind = kind });
    }
    return exec.js.local.?.resolvePromise(devices);
}

/// A denied-permission browser rejects with NotAllowedError. Doing the same is
/// both truthful (no stream exists) and the least suspicious outcome.
pub fn getUserMedia(_: *const MediaDevices, _: ?js.Value, exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NotAllowedError } });
}

pub fn getDisplayMedia(self: *const MediaDevices, constraints: ?js.Value, exec: *const Execution) js.Promise {
    return self.getUserMedia(constraints, exec);
}

/// Chrome 131 desktop reports every one of these as `true`.
const supported_constraints = [_][]const u8{
    "aspectRatio",          "autoGainControl",            "brightness",
    "channelCount",         "colorTemperature",           "contrast",
    "deviceId",             "displaySurface",             "echoCancellation",
    "exposureCompensation", "exposureMode",               "exposureTime",
    "facingMode",           "focusDistance",              "focusMode",
    "frameRate",            "groupId",                    "height",
    "iso",                  "latency",                    "noiseSuppression",
    "pan",                  "pointsOfInterest",           "resizeMode",
    "sampleRate",           "sampleSize",                 "saturation",
    "sharpness",            "suppressLocalAudioPlayback", "tilt",
    "torch",                "whiteBalanceMode",           "width",
    "zoom",
};

pub fn getSupportedConstraints(_: *const MediaDevices, exec: *const Execution) !js.Object {
    const obj = exec.js.local.?.newObject();
    for (supported_constraints) |name| {
        _ = try obj.set(name, true, .{});
    }
    return obj;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaDevices);

    pub const Meta = struct {
        pub const name = "MediaDevices";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const enumerateDevices = bridge.function(MediaDevices.enumerateDevices, .{});
    pub const getUserMedia = bridge.function(MediaDevices.getUserMedia, .{});
    pub const getDisplayMedia = bridge.function(MediaDevices.getDisplayMedia, .{});
    pub const getSupportedConstraints = bridge.function(MediaDevices.getSupportedConstraints, .{});
};

pub const MediaDeviceInfo = struct {
    _kind: []const u8,

    pub fn getDeviceId(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }
    pub fn getGroupId(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }
    pub fn getLabel(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }
    pub fn getKind(self: *const MediaDeviceInfo) []const u8 {
        return self._kind;
    }

    pub fn toJSON(self: *const MediaDeviceInfo, exec: *const Execution) !js.Object {
        const obj = exec.js.local.?.newObject();
        _ = try obj.set("deviceId", "", .{});
        _ = try obj.set("kind", self._kind, .{});
        _ = try obj.set("label", "", .{});
        _ = try obj.set("groupId", "", .{});
        return obj;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaDeviceInfo);

        pub const Meta = struct {
            pub const name = "MediaDeviceInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const deviceId = bridge.accessor(MediaDeviceInfo.getDeviceId, null, .{});
        pub const groupId = bridge.accessor(MediaDeviceInfo.getGroupId, null, .{});
        pub const label = bridge.accessor(MediaDeviceInfo.getLabel, null, .{});
        pub const kind = bridge.accessor(MediaDeviceInfo.getKind, null, .{});
        pub const toJSON = bridge.function(MediaDeviceInfo.toJSON, .{});
    };
};
