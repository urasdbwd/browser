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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");

const String = lp.String;

/// https://drafts.csswg.org/cssom-view/#mediaquerylistevent
const MediaQueryListEvent = @This();

pub const Proto = Event;

_proto: *Event,
_media: []const u8 = "",
_matches: bool = false,

const MediaQueryListEventOptions = struct {
    media: []const u8 = "",
    matches: bool = false,
};

const Options = Event.inheritOptions(MediaQueryListEvent, MediaQueryListEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, frame: *Frame) !*MediaQueryListEvent {
    const arena = try frame.getArena(.tiny, "MediaQueryListEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, frame);
}

pub fn initTrusted(typ: String, opts_: ?Options, frame: *Frame) !*MediaQueryListEvent {
    const arena = try frame.getArena(.tiny, "MediaQueryListEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, opts_, true, frame);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, opts_: ?Options, trusted: bool, frame: *Frame) !*MediaQueryListEvent {
    const opts = opts_ orelse Options{};

    const event = try frame._factory.event(
        arena,
        typ,
        MediaQueryListEvent{
            ._proto = undefined,
            ._media = if (opts.media.len > 0) try arena.dupe(u8, opts.media) else "",
            ._matches = opts.matches,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *MediaQueryListEvent) *Event {
    return self._proto;
}

pub fn getMedia(self: *const MediaQueryListEvent) []const u8 {
    return self._media;
}

pub fn getMatches(self: *const MediaQueryListEvent) bool {
    return self._matches;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaQueryListEvent);

    pub const Meta = struct {
        pub const name = "MediaQueryListEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(MediaQueryListEvent.init, .{});
    pub const media = bridge.accessor(MediaQueryListEvent.getMedia, null, .{});
    pub const matches = bridge.accessor(MediaQueryListEvent.getMatches, null, .{});
};
