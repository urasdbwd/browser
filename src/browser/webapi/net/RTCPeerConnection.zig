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

//! A non-connecting `RTCPeerConnection`. Its absence is a headless tell, so the
//! constructor and the full feature-detection surface exist, but nothing here
//! opens a socket.
//!
//! Deliberately NOT faked: ICE candidates. The offers produced below carry no
//! `a=candidate:` lines and no host/srflx address, so the classic "WebRTC IP
//! leak" probe observes the honest outcome — gathering completes with zero
//! candidates. Inventing a candidate would leak a fabricated (and, behind a
//! proxy, contradictory) IP, which is strictly worse than gathering nothing.

const std = @import("std");

const js = @import("../../js/js.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ RTCPeerConnection, RTCDataChannel };
}

const RTCPeerConnection = @This();

/// Session id for the SDP `o=` line. Seeded, so it is stable per instance and
/// differs across fingerprints, like a real session id.
_session_id: u64,
_closed: bool = false,

pub fn constructor(_: ?js.Value, exec: *const Execution) !*RTCPeerConnection {
    const seed = exec.session.browser.app.config.fingerprint_profile.noise_seed;
    return exec._factory.create(RTCPeerConnection{
        // Keep it in the 63-bit range browsers use for o= session ids.
        ._session_id = (seed ^ 0x5254_4350_4545_5200) >> 1,
    });
}

fn state(self: *const RTCPeerConnection, open: []const u8) []const u8 {
    return if (self._closed) "closed" else open;
}

pub fn getSignalingState(self: *const RTCPeerConnection) []const u8 {
    return self.state("stable");
}

pub fn getIceGatheringState(self: *const RTCPeerConnection) []const u8 {
    return self.state("new");
}

pub fn getIceConnectionState(self: *const RTCPeerConnection) []const u8 {
    return self.state("new");
}

pub fn getConnectionState(self: *const RTCPeerConnection) []const u8 {
    return self.state("new");
}

pub fn getLocalDescription(_: *const RTCPeerConnection) ?js.Value {
    return null;
}

pub fn getRemoteDescription(_: *const RTCPeerConnection) ?js.Value {
    return null;
}

pub fn getCanTrickleIceCandidates(_: *const RTCPeerConnection) ?bool {
    return null;
}

/// Minimal, candidate-free SDP. Every line here is generic protocol framing —
/// none of it identifies the host.
fn sessionDescription(self: *const RTCPeerConnection, kind: []const u8, exec: *const Execution) !js.Object {
    const sdp = try std.fmt.allocPrint(exec.arena,
        \\v=0
        \\o=- {d} 2 IN IP4 127.0.0.1
        \\s=-
        \\t=0 0
        \\a=group:BUNDLE 0
        \\a=msid-semantic: WMS
        \\m=application 9 UDP/DTLS/SCTP webrtc-datachannel
        \\c=IN IP4 0.0.0.0
        \\a=ice-ufrag:{x}
        \\a=ice-pwd:{x}{x}
        \\a=setup:actpass
        \\a=mid:0
        \\a=sctp-port:5000
        \\a=max-message-size:262144
        \\
    , .{
        self._session_id,
        @as(u32, @truncate(self._session_id)),
        @as(u32, @truncate(self._session_id >> 16)),
        @as(u32, @truncate(self._session_id >> 32)),
    });

    const obj = exec.js.local.?.newObject();
    _ = try obj.set("type", kind, .{});
    _ = try obj.set("sdp", sdp, .{});
    return obj;
}

pub fn createOffer(self: *RTCPeerConnection, _: ?js.Value, exec: *const Execution) !js.Promise {
    if (self._closed) return error.InvalidStateError;
    return exec.js.local.?.resolvePromise(try self.sessionDescription("offer", exec));
}

pub fn createAnswer(self: *RTCPeerConnection, _: ?js.Value, exec: *const Execution) !js.Promise {
    if (self._closed) return error.InvalidStateError;
    return exec.js.local.?.resolvePromise(try self.sessionDescription("answer", exec));
}

pub fn setLocalDescription(self: *RTCPeerConnection, _: ?js.Value, exec: *const Execution) !js.Promise {
    if (self._closed) return error.InvalidStateError;
    return exec.js.local.?.resolvePromise({});
}

pub fn setRemoteDescription(self: *RTCPeerConnection, _: ?js.Value, exec: *const Execution) !js.Promise {
    if (self._closed) return error.InvalidStateError;
    return exec.js.local.?.resolvePromise({});
}

pub fn addIceCandidate(_: *RTCPeerConnection, _: ?js.Value, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise({});
}

pub fn createDataChannel(_: *RTCPeerConnection, label: []const u8, _: ?js.Value, exec: *const Execution) !*RTCDataChannel {
    return exec._factory.create(RTCDataChannel{ ._label = try exec.arena.dupe(u8, label) });
}

/// Chrome resolves an RTCStatsReport. Nothing is being transported, so there
/// are no stats to report; an empty object keeps `for (const s of report)`-style
/// probes from throwing on the common `.forEach`-free paths.
pub fn getStats(_: *const RTCPeerConnection, _: ?js.Value, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(exec.js.local.?.newObject());
}

pub fn getConfiguration(_: *const RTCPeerConnection, exec: *const Execution) !js.Object {
    const obj = exec.js.local.?.newObject();
    _ = try obj.set("bundlePolicy", "balanced", .{});
    _ = try obj.set("iceTransportPolicy", "all", .{});
    _ = try obj.set("rtcpMuxPolicy", "require", .{});
    return obj;
}

fn emptyArray(exec: *const Execution) js.Value {
    var array = exec.js.local.?.newArray(0);
    return array.toValue();
}

pub fn getSenders(_: *const RTCPeerConnection, exec: *const Execution) js.Value {
    return emptyArray(exec);
}

pub fn getReceivers(_: *const RTCPeerConnection, exec: *const Execution) js.Value {
    return emptyArray(exec);
}

pub fn getTransceivers(_: *const RTCPeerConnection, exec: *const Execution) js.Value {
    return emptyArray(exec);
}

pub fn close(self: *RTCPeerConnection) void {
    self._closed = true;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCPeerConnection);

    pub const Meta = struct {
        pub const name = "RTCPeerConnection";
        pub const constructor_alias = "webkitRTCPeerConnection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(RTCPeerConnection.constructor, .{});

    pub const signalingState = bridge.accessor(RTCPeerConnection.getSignalingState, null, .{});
    pub const iceGatheringState = bridge.accessor(RTCPeerConnection.getIceGatheringState, null, .{});
    pub const iceConnectionState = bridge.accessor(RTCPeerConnection.getIceConnectionState, null, .{});
    pub const connectionState = bridge.accessor(RTCPeerConnection.getConnectionState, null, .{});
    pub const localDescription = bridge.accessor(RTCPeerConnection.getLocalDescription, null, .{});
    pub const remoteDescription = bridge.accessor(RTCPeerConnection.getRemoteDescription, null, .{});
    pub const canTrickleIceCandidates = bridge.accessor(RTCPeerConnection.getCanTrickleIceCandidates, null, .{});

    pub const createOffer = bridge.function(RTCPeerConnection.createOffer, .{});
    pub const createAnswer = bridge.function(RTCPeerConnection.createAnswer, .{});
    pub const setLocalDescription = bridge.function(RTCPeerConnection.setLocalDescription, .{});
    pub const setRemoteDescription = bridge.function(RTCPeerConnection.setRemoteDescription, .{});
    pub const addIceCandidate = bridge.function(RTCPeerConnection.addIceCandidate, .{});
    pub const createDataChannel = bridge.function(RTCPeerConnection.createDataChannel, .{});
    pub const getStats = bridge.function(RTCPeerConnection.getStats, .{});
    pub const getConfiguration = bridge.function(RTCPeerConnection.getConfiguration, .{});
    pub const getSenders = bridge.function(RTCPeerConnection.getSenders, .{});
    pub const getReceivers = bridge.function(RTCPeerConnection.getReceivers, .{});
    pub const getTransceivers = bridge.function(RTCPeerConnection.getTransceivers, .{});
    pub const close = bridge.function(RTCPeerConnection.close, .{});
};

pub const RTCDataChannel = struct {
    _label: []const u8,
    _closed: bool = false,

    pub fn getLabel(self: *const RTCDataChannel) []const u8 {
        return self._label;
    }
    pub fn getReadyState(self: *const RTCDataChannel) []const u8 {
        return if (self._closed) "closed" else "connecting";
    }
    pub fn getOrdered(_: *const RTCDataChannel) bool {
        return true;
    }
    pub fn getBufferedAmount(_: *const RTCDataChannel) u32 {
        return 0;
    }
    pub fn send(_: *const RTCDataChannel, _: ?js.Value) void {}
    pub fn close(self: *RTCDataChannel) void {
        self._closed = true;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(RTCDataChannel);

        pub const Meta = struct {
            pub const name = "RTCDataChannel";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const label = bridge.accessor(RTCDataChannel.getLabel, null, .{});
        pub const readyState = bridge.accessor(RTCDataChannel.getReadyState, null, .{});
        pub const ordered = bridge.accessor(RTCDataChannel.getOrdered, null, .{});
        pub const bufferedAmount = bridge.accessor(RTCDataChannel.getBufferedAmount, null, .{});
        pub const send = bridge.function(RTCDataChannel.send, .{ .noop = true });
        pub const close = bridge.function(RTCDataChannel.close, .{});
    };
};
