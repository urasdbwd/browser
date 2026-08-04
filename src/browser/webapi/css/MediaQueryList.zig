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

// zlint-disable unused-decls
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const EventTarget = @import("../EventTarget.zig");
const MediaQuery = @import("../../css/MediaQuery.zig");
const MediaQueryListEvent = @import("../event/MediaQueryListEvent.zig");

const log = lp.log;

const MediaQueryList = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_media: []const u8,
// The last evaluated result. `change` fires when a re-evaluation disagrees.
_matches: bool,
_on_change: ?js.Function.Global = null,

pub fn init(query: []const u8, frame: *Frame) !*MediaQueryList {
    const media = try frame.dupeString(query);
    const self = try frame._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = media,
        ._matches = MediaQuery.matches(media, frame._page.getViewport()),
    });
    try frame._media_query_lists.append(frame.arena, self);
    return self;
}

pub fn deinit(self: *MediaQueryList) void {
    _ = self;
}

pub fn asEventTarget(self: *MediaQueryList) *EventTarget {
    return self._proto;
}

pub fn getMedia(self: *const MediaQueryList) []const u8 {
    return self._media;
}

/// Re-evaluates the stored query against the current viewport on every call
/// so the result stays in sync with viewport emulation. The viewport comes
/// from the page (overridable via Emulation.setDeviceMetricsOverride),
/// matching `Window.innerWidth` / `innerHeight`.
pub fn getMatches(self: *const MediaQueryList, frame: *Frame) bool {
    return MediaQuery.matches(self._media, frame._page.getViewport());
}

pub fn getOnChange(self: *const MediaQueryList) ?js.Function.Global {
    return self._on_change;
}

pub fn setOnChange(self: *MediaQueryList, cb: ?js.Function.Global) void {
    self._on_change = cb;
}

// The legacy `addListener` / `removeListener` are defined by the spec as
// aliases of addEventListener / removeEventListener for the "change" type,
// so both registration styles land in the same listener list.
pub fn addListener(self: *MediaQueryList, callback: js.Nullable(EventTarget.EventListenerCallback), exec: *js.Execution) !void {
    return self.asEventTarget().addEventListener("change", callback, null, exec);
}

pub fn removeListener(self: *MediaQueryList, callback: js.Nullable(EventTarget.EventListenerCallback), exec: *js.Execution) !void {
    return self.asEventTarget().removeEventListener("change", callback, null, exec);
}

/// Re-evaluates every live query in `frame`, firing `change` on the ones whose
/// result flipped. Called once per event loop tick after the viewport changes.
pub fn deliverChanges(frame: *Frame) void {
    const viewport = frame._page.getViewport();
    for (frame._media_query_lists.items) |self| {
        const matches = MediaQuery.matches(self._media, viewport);
        if (matches == self._matches) {
            continue;
        }
        self._matches = matches;
        self.dispatchChange(frame) catch |err| {
            log.err(.frame, "MediaQueryList.change", .{ .err = err, .media = self._media });
        };
    }
}

fn dispatchChange(self: *MediaQueryList, frame: *Frame) !void {
    const target = self.asEventTarget();
    const on_change = self._on_change;
    if (!frame._event_manager.hasDirectListeners(target, "change", on_change)) {
        return;
    }

    const event = (try MediaQueryListEvent.initTrusted(comptime .wrap("change"), .{
        .media = self._media,
        .matches = self._matches,
    }, frame)).asEvent();
    try frame._event_manager.dispatchDirect(target, event, on_change, .{ .context = "MediaQueryList.change" });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaQueryList);

    pub const Meta = struct {
        pub const name = "MediaQueryList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const media = bridge.accessor(MediaQueryList.getMedia, null, .{});
    pub const matches = bridge.accessor(MediaQueryList.getMatches, null, .{});
    pub const onchange = bridge.accessor(MediaQueryList.getOnChange, MediaQueryList.setOnChange, .{});
    pub const addListener = bridge.function(MediaQueryList.addListener, .{});
    pub const removeListener = bridge.function(MediaQueryList.removeListener, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaQueryList" {
    try testing.htmlRunner("css/media_query_list.html", .{});
}

test "WebApi: media @-rule cascade" {
    try testing.htmlRunner("css/media_at_rule_cascade.html", .{});
}
