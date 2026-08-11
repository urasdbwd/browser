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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const EventCounts = @import("EventCounts.zig");
const PerformanceObserver = @import("PerformanceObserver.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ Performance, Entry, Mark, Measure, NavigationTiming, PerformanceTiming, PerformanceNavigation, MemoryInfo };
}

const Performance = @This();

_time_origin: u64,
_time_origin_epoch_ms: f64,
_entries: std.ArrayList(*Entry) = .empty,
_navigation_timing: ?*NavigationTiming = null,
_timing: PerformanceTiming = .{},
_navigation: PerformanceNavigation = .{},
_memory: MemoryInfo = .{},
_event_counts: EventCounts = .{},

// Navigation milestones, in ms since `_time_origin`. 0 until they fire.
// Consumed by chrome.csi()/chrome.loadTimes(), which scanners compare against
// performance.now().
_dom_content_loaded: f64 = 0,
_load_event_end: f64 = 0,

// PerformanceObserver infrastructure. Lives here (rather than on the owning
// Frame/WorkerGlobalScope) so that both contexts get observers for free.
_observers: std.ArrayList(*PerformanceObserver) = .empty,
_delivery_scheduled: bool = false,

/// Get the monotonic timestamp in microseconds.
pub fn highResTimestamp() u64 {
    return lp.datetime.microTimestamp(.boot);
}

pub fn init() Performance {
    const epoch_ms = @as(f64, @floatFromInt(lp.datetime.microTimestamp(.real))) / 1000.0;
    return .{
        ._time_origin = highResTimestamp(),
        ._time_origin_epoch_ms = @floor(epoch_ms * 10.0) / 10.0,
        ._timing = .init(epoch_ms),
    };
}

pub fn getTiming(self: *Performance) *PerformanceTiming {
    return &self._timing;
}

pub fn getMemory(self: *Performance) *MemoryInfo {
    return &self._memory;
}

pub fn now(self: *const Performance) f64 {
    const current = highResTimestamp();
    const elapsed = current - self._time_origin;
    // Chrome reduces the clock to 100-microsecond precision.
    const milliseconds = @as(f64, @floatFromInt(elapsed)) / 1000.0;
    return @floor(milliseconds * 10.0) / 10.0;
}

pub fn markDomContentLoaded(self: *Performance) void {
    if (self._dom_content_loaded == 0) {
        self._dom_content_loaded = self.now();
        self._timing.markDomContentLoaded(self._time_origin_epoch_ms + self._dom_content_loaded);
    }
}

pub const NetworkTiming = struct {
    name_lookup_micros: i64 = 0,
    connect_micros: i64 = 0,
    app_connect_micros: i64 = 0,
    pre_transfer_micros: i64 = 0,
    start_transfer_micros: i64 = 0,
    connection_reused: bool = false,
};

pub fn markResponseStart(self: *Performance, transfer_start_micros: u64, timing: NetworkTiming) void {
    var resolved_timing = timing;
    // Synthetic responses (for example CDP Fetch.fulfillRequest) have no curl
    // timing data. Keep their request phases at transfer start, but record the
    // actual header-arrival time instead of collapsing responseStart onto
    // navigationStart.
    if (resolved_timing.start_transfer_micros == 0) {
        resolved_timing.start_transfer_micros = if (transfer_start_micros == 0)
            @intFromFloat(self.now() * 1000.0)
        else
            @intCast(highResTimestamp() -| transfer_start_micros);
    }
    const transfer_offset_micros = if (transfer_start_micros > self._time_origin)
        transfer_start_micros - self._time_origin
    else
        0;
    const transfer_epoch_ms = self._time_origin_epoch_ms +
        @as(f64, @floatFromInt(transfer_offset_micros)) / 1000.0;
    self._timing.markResponseStart(transfer_epoch_ms, resolved_timing);
}

pub fn markResponseEnd(self: *Performance) void {
    self._timing.markResponseEnd(self._time_origin_epoch_ms, self.now());
}

pub fn markLoadEventEnd(self: *Performance) void {
    if (self._load_event_end == 0) {
        self._load_event_end = self.now();
        self._timing.markLoadEventEnd(self._time_origin_epoch_ms + self._load_event_end);
    }
}

pub fn getTimeOrigin(self: *const Performance) f64 {
    return self._time_origin_epoch_ms;
}

pub fn getNavigation(self: *Performance) *PerformanceNavigation {
    return &self._navigation;
}

pub fn getEventCounts(self: *Performance) *EventCounts {
    return &self._event_counts;
}

pub fn mark(
    self: *Performance,
    name: []const u8,
    _options: ?Mark.Options,
    exec: *const Execution,
) !*Mark {
    const opts = _options orelse Mark.Options{};
    const start_time = opts.startTime orelse self.now();
    const m = try Mark.init(name, opts.detail, start_time, exec);
    try self._entries.append(exec.arena, m._proto);
    try self.notifyObservers(m._proto, exec);
    return m;
}

const MeasureOptionsOrStartMark = union(enum) {
    measure_options: Measure.Options,
    start_mark: []const u8,
};

pub fn measure(
    self: *Performance,
    name: []const u8,
    maybe_options_or_start: ?MeasureOptionsOrStartMark,
    maybe_end_mark: ?[]const u8,
    exec: *const Execution,
) !*Measure {
    if (maybe_options_or_start) |options_or_start| switch (options_or_start) {
        .measure_options => |options| {
            // Get start timestamp.
            const start_timestamp = blk: {
                if (options.start) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk 0.0;
            };

            // Get end timestamp.
            const end_timestamp = blk: {
                if (options.end) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                options.detail,
                start_timestamp,
                end_timestamp,
                options.duration,
                exec,
            );
            try self._entries.append(exec.arena, m._proto);
            try self.notifyObservers(m._proto, exec);
            return m;
        },
        .start_mark => |start_mark| {
            // Get start timestamp.
            const start_timestamp = try self.getMarkTime(start_mark);
            // Get end timestamp.
            const end_timestamp = blk: {
                if (maybe_end_mark) |mark_name| {
                    break :blk try self.getMarkTime(mark_name);
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                null,
                start_timestamp,
                end_timestamp,
                null,
                exec,
            );
            try self._entries.append(exec.arena, m._proto);
            try self.notifyObservers(m._proto, exec);
            return m;
        },
    };

    const m = try Measure.init(name, null, 0.0, self.now(), null, exec);
    try self._entries.append(exec.arena, m._proto);
    try self.notifyObservers(m._proto, exec);
    return m;
}

pub fn clearMarks(self: *Performance, mark_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .mark and (mark_name == null or std.mem.eql(u8, entry._name, mark_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn clearMeasures(self: *Performance, measure_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .measure and (measure_name == null or std.mem.eql(u8, entry._name, measure_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn setResourceTimingBufferSize(self: *Performance, max_size: u32) void {
    _ = self;
    _ = max_size;
}

pub fn getEntries(self: *const Performance) []*Entry {
    return self._entries.items;
}

pub fn getEntriesByType(self: *const Performance, entry_type: []const u8, exec: *const Execution) ![]const *Entry {
    if (std.mem.eql(u8, entry_type, "navigation")) {
        const navigation = try @constCast(self).getNavigationTiming(exec);
        const entries = try exec.local_arena.alloc(*Entry, 1);
        entries[0] = navigation._proto;
        return entries;
    }
    return filterEntriesByType(exec.local_arena, self._entries.items, entry_type);
}

fn getNavigationTiming(self: *Performance, exec: *const Execution) !*NavigationTiming {
    if (self._navigation_timing) |navigation| return navigation;

    const navigation = try NavigationTiming.init(self, exec);
    self._navigation_timing = navigation;
    return navigation;
}

pub fn getEntriesByName(self: *const Performance, name: []const u8, entry_type: ?[]const u8, exec: *const Execution) ![]const *Entry {
    return filterEntriesByName(exec.local_arena, self._entries.items, name, entry_type);
}

// Also used by PerformanceObserver
pub fn filterEntriesByType(arena: Allocator, list: []*Entry, entry_type: []const u8) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.getEntryType(), entry_type)) {
            try result.append(arena, entry);
        }
    }
    return result.items;
}

// Also used by PerformanceObserver
pub fn filterEntriesByName(arena: Allocator, list: []*Entry, name: []const u8, entry_type: ?[]const u8) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;

    for (list) |entry| {
        if (!std.mem.eql(u8, entry._name, name)) {
            continue;
        }
        if (entry_type == null or std.mem.eql(u8, entry.getEntryType(), entry_type.?)) {
            try result.append(arena, entry);
        }
    }

    return result.items;
}

fn getMarkTime(self: *const Performance, mark_name: []const u8) !f64 {
    for (self._entries.items) |entry| {
        if (entry._type == .mark and std.mem.eql(u8, entry._name, mark_name)) {
            return entry._start_time;
        }
    }

    // PerformanceTiming attribute names are valid start/end marks per the
    // W3C User Timing Level 2 spec. All are relative to navigationStart (= 0).
    // https://www.w3.org/TR/user-timing/#dom-performance-measure
    //
    // `navigationStart` is an equivalent to 0.
    // Others are dependant to request arrival, end of request etc, but we
    // return a dummy 0 value for now.
    const navigation_timing_marks = std.StaticStringMap(void).initComptime(.{
        .{ "navigationStart", {} },
        .{ "unloadEventStart", {} },
        .{ "unloadEventEnd", {} },
        .{ "redirectStart", {} },
        .{ "redirectEnd", {} },
        .{ "fetchStart", {} },
        .{ "domainLookupStart", {} },
        .{ "domainLookupEnd", {} },
        .{ "connectStart", {} },
        .{ "connectEnd", {} },
        .{ "secureConnectionStart", {} },
        .{ "requestStart", {} },
        .{ "responseStart", {} },
        .{ "responseEnd", {} },
        .{ "domLoading", {} },
        .{ "domInteractive", {} },
        .{ "domContentLoadedEventStart", {} },
        .{ "domContentLoadedEventEnd", {} },
        .{ "domComplete", {} },
        .{ "loadEventStart", {} },
        .{ "loadEventEnd", {} },
    });
    if (navigation_timing_marks.has(mark_name)) {
        return 0;
    }

    return error.SyntaxError; // Mark not found
}

pub fn registerObserver(self: *Performance, observer: *PerformanceObserver, exec: *const Execution) !void {
    return self._observers.append(exec.arena, observer);
}

pub fn unregisterObserver(self: *Performance, observer: *PerformanceObserver) void {
    for (self._observers.items, 0..) |o, i| {
        if (o == observer) {
            _ = self._observers.swapRemove(i);
            return;
        }
    }
}

/// Append the entry to every interested observer's queue and schedule async
/// delivery. Does NOT fire the callbacks synchronously — that happens later
/// via the scheduled task.
pub fn notifyObservers(self: *Performance, entry: *Entry, exec: *const Execution) !void {
    for (self._observers.items) |observer| {
        if (observer.interested(entry)) {
            observer._entries.append(exec.arena, entry) catch |err| {
                lp.log.err(.frame, "Performance.notifyObservers", .{ .err = err });
            };
        }
    }

    try self.scheduleDelivery(exec);
}

pub fn scheduleDelivery(self: *Performance, exec: *const Execution) !void {
    if (self._delivery_scheduled) {
        return;
    }
    self._delivery_scheduled = true;

    return exec._scheduler.add(
        self,
        struct {
            fn run(_self: *anyopaque) anyerror!?u32 {
                const perf: *Performance = @ptrCast(@alignCast(_self));
                perf._delivery_scheduled = false;
                for (perf._observers.items) |observer| {
                    if (observer.hasRecords()) {
                        try observer.dispatch();
                    }
                }
                return null;
            }
        }.run,
        0,
        .{ .name = "Performance.deliverObservers" },
    );
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Performance);

    pub const Meta = struct {
        pub const name = "Performance";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const now = bridge.function(Performance.now, .{});
    pub const mark = bridge.function(Performance.mark, .{});
    pub const measure = bridge.function(Performance.measure, .{});
    pub const clearMarks = bridge.function(Performance.clearMarks, .{});
    pub const clearMeasures = bridge.function(Performance.clearMeasures, .{});
    pub const setResourceTimingBufferSize = bridge.function(Performance.setResourceTimingBufferSize, .{ .noop = true });
    pub const getEntries = bridge.function(Performance.getEntries, .{});
    pub const getEntriesByType = bridge.function(Performance.getEntriesByType, .{});
    pub const getEntriesByName = bridge.function(Performance.getEntriesByName, .{});
    pub const timeOrigin = bridge.accessor(Performance.getTimeOrigin, null, .{});
    pub const timing = bridge.accessor(Performance.getTiming, null, .{ .exposed = .window });
    pub const navigation = bridge.accessor(Performance.getNavigation, null, .{ .exposed = .window });
    pub const eventCounts = bridge.accessor(Performance.getEventCounts, null, .{ .exposed = .window });
    pub const memory = bridge.accessor(Performance.getMemory, null, .{ .exposed = .window });
};

pub const Entry = struct {
    _duration: f64 = 0.0,
    _type: Type,
    _name: []const u8,
    _start_time: f64 = 0.0,

    pub const Type = union(Enum) {
        element,
        event,
        first_input,
        @"largest-contentful-paint",
        @"layout-shift",
        @"long-animation-frame",
        longtask,
        measure: *Measure,
        navigation: *NavigationTiming,
        paint,
        resource,
        taskattribution,
        @"visibility-state",
        mark: *Mark,

        pub const Enum = enum(u8) {
            element = 1, // Changing this affect PerformanceObserver's behavior.
            event = 2,
            first_input = 3,
            @"largest-contentful-paint" = 4,
            @"layout-shift" = 5,
            @"long-animation-frame" = 6,
            longtask = 7,
            measure = 8,
            navigation = 9,
            paint = 10,
            resource = 11,
            taskattribution = 12,
            @"visibility-state" = 13,
            mark = 14,
            // If we ever have types more than 16, we have to update entry
            // table of PerformanceObserver too.
        };
    };

    pub fn getDuration(self: *const Entry) f64 {
        return self._duration;
    }

    pub fn getEntryType(self: *const Entry) []const u8 {
        return switch (self._type) {
            else => |t| @tagName(t),
        };
    }

    pub fn getName(self: *const Entry) []const u8 {
        return self._name;
    }

    pub fn getStartTime(self: *const Entry) f64 {
        return self._start_time;
    }

    pub fn toJSON(self: *const Entry) struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
    } {
        return .{
            .name = self.getName(),
            .entryType = self.getEntryType(),
            .startTime = self.getStartTime(),
            .duration = self.getDuration(),
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Entry);

        pub const Meta = struct {
            pub const name = "PerformanceEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const name = bridge.accessor(Entry.getName, null, .{});
        pub const duration = bridge.accessor(Entry.getDuration, null, .{});
        pub const entryType = bridge.accessor(Entry.getEntryType, null, .{});
        pub const startTime = bridge.accessor(Entry.getStartTime, null, .{});
        pub const toJSON = bridge.function(Entry.toJSON, .{});
    };
};

pub const Mark = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        startTime: ?f64 = null,
    };

    pub fn init(name: []const u8, maybe_detail: ?js.Value, start_time: f64, exec: *const Execution) !*Mark {
        if (start_time < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try exec._factory.chained(.{
            Entry{
                ._start_time = start_time,
                ._name = try exec.dupeString(name),
                ._type = undefined,
            },
            Mark{
                ._proto = undefined,
                ._detail = detail,
            },
        });
        m._proto._type = .{ .mark = m };
        return m;
    }

    pub fn getDetail(self: *const Mark) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Mark);

        pub const Meta = struct {
            pub const name = "PerformanceMark";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Mark.getDetail, null, .{});
    };
};

pub const Measure = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        start: ?TimestampOrMark,
        end: ?TimestampOrMark,
        duration: ?f64 = null,

        const TimestampOrMark = union(enum) {
            timestamp: f64,
            mark: []const u8,
        };
    };

    pub fn init(
        name: []const u8,
        maybe_detail: ?js.Value,
        start_timestamp: f64,
        end_timestamp: f64,
        maybe_duration: ?f64,
        exec: *const Execution,
    ) !*Measure {
        const duration = maybe_duration orelse (end_timestamp - start_timestamp);
        if (duration < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try exec._factory.chained(.{
            Entry{
                ._start_time = start_timestamp,
                ._duration = duration,
                ._name = try exec.dupeString(name),
                ._type = undefined,
            },
            Measure{
                ._proto = undefined,
                ._detail = detail,
            },
        });
        m._proto._type = .{ .measure = m };
        return m;
    }

    pub fn getDetail(self: *const Measure) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Measure);

        pub const Meta = struct {
            pub const name = "PerformanceMeasure";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Measure.getDetail, null, .{});
    };
};

/// Navigation Timing Level 2 entry for the current document.
pub const NavigationTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _performance: *Performance,

    fn init(performance: *Performance, exec: *const Execution) !*NavigationTiming {
        const navigation = try exec._factory.chained(.{
            Entry{
                ._duration = performance.now(),
                ._type = undefined,
                ._name = try exec.dupeString(exec.url.*),
            },
            NavigationTiming{
                ._proto = undefined,
                ._performance = performance,
            },
        });
        navigation._proto._type = .{ .navigation = navigation };
        return navigation;
    }

    fn relative(self: *const NavigationTiming, value: f64) f64 {
        if (value == 0) return 0;
        return value - self._performance._timing.navigation_start;
    }

    pub fn getDuration(self: *const NavigationTiming) f64 {
        return self._performance.now();
    }

    pub fn getFetchStart(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.fetch_start);
    }

    pub fn getDomainLookupStart(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.domain_lookup_start);
    }

    pub fn getDomainLookupEnd(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.domain_lookup_end);
    }

    pub fn getConnectStart(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.connect_start);
    }

    pub fn getSecureConnectionStart(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.secure_connection_start);
    }

    pub fn getConnectEnd(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.connect_end);
    }

    pub fn getRequestStart(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.request_start);
    }

    pub fn getResponseStart(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.response_start);
    }

    pub fn getResponseEnd(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.response_end);
    }

    pub fn getDomInteractive(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.dom_interactive);
    }

    pub fn getDomContentLoadedEventStart(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.dom_content_loaded_event_start);
    }

    pub fn getDomContentLoadedEventEnd(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.dom_content_loaded_event_end);
    }

    pub fn getDomComplete(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.dom_complete);
    }

    pub fn getLoadEventStart(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.load_event_start);
    }

    pub fn getLoadEventEnd(self: *const NavigationTiming) f64 {
        return self.relative(self._performance._timing.load_event_end);
    }

    pub fn toJSON(self: *const NavigationTiming) struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
        initiatorType: []const u8,
        deliveryType: []const u8,
        nextHopProtocol: []const u8,
        renderBlockingStatus: []const u8,
        contentType: []const u8,
        contentEncoding: []const u8,
        workerStart: f64,
        workerRouterEvaluationStart: f64,
        workerCacheLookupStart: f64,
        workerMatchedSourceType: []const u8,
        workerFinalSourceType: []const u8,
        redirectStart: f64,
        redirectEnd: f64,
        fetchStart: f64,
        domainLookupStart: f64,
        domainLookupEnd: f64,
        connectStart: f64,
        secureConnectionStart: f64,
        connectEnd: f64,
        requestStart: f64,
        responseStart: f64,
        firstInterimResponseStart: f64,
        finalResponseHeadersStart: f64,
        responseEnd: f64,
        transferSize: u32,
        encodedBodySize: u32,
        decodedBodySize: u32,
        responseStatus: u16,
        serverTiming: [0]u8,
        unloadEventStart: f64,
        unloadEventEnd: f64,
        domInteractive: f64,
        domContentLoadedEventStart: f64,
        domContentLoadedEventEnd: f64,
        domComplete: f64,
        loadEventStart: f64,
        loadEventEnd: f64,
        type: []const u8,
        redirectCount: u32,
        activationStart: f64,
        criticalCHRestart: f64,
        notRestoredReasons: ?u8,
    } {
        return .{
            .name = self._proto.getName(),
            .entryType = self._proto.getEntryType(),
            .startTime = self._proto.getStartTime(),
            .duration = self.getDuration(),
            .initiatorType = "navigation",
            .deliveryType = "",
            .nextHopProtocol = "h2",
            .renderBlockingStatus = "non-blocking",
            .contentType = "text/html",
            .contentEncoding = "",
            .workerStart = 0,
            .workerRouterEvaluationStart = 0,
            .workerCacheLookupStart = 0,
            .workerMatchedSourceType = "",
            .workerFinalSourceType = "",
            .redirectStart = 0,
            .redirectEnd = 0,
            .fetchStart = self.getFetchStart(),
            .domainLookupStart = self.getDomainLookupStart(),
            .domainLookupEnd = self.getDomainLookupEnd(),
            .connectStart = self.getConnectStart(),
            .secureConnectionStart = self.getSecureConnectionStart(),
            .connectEnd = self.getConnectEnd(),
            .requestStart = self.getRequestStart(),
            .responseStart = self.getResponseStart(),
            .firstInterimResponseStart = 0,
            .finalResponseHeadersStart = 0,
            .responseEnd = self.getResponseEnd(),
            .transferSize = 0,
            .encodedBodySize = 0,
            .decodedBodySize = 0,
            .responseStatus = 200,
            .serverTiming = .{},
            .unloadEventStart = 0,
            .unloadEventEnd = 0,
            .domInteractive = self.getDomInteractive(),
            .domContentLoadedEventStart = self.getDomContentLoadedEventStart(),
            .domContentLoadedEventEnd = self.getDomContentLoadedEventEnd(),
            .domComplete = self.getDomComplete(),
            .loadEventStart = self.getLoadEventStart(),
            .loadEventEnd = self.getLoadEventEnd(),
            .type = "navigate",
            .redirectCount = 0,
            .activationStart = 0,
            .criticalCHRestart = 0,
            .notRestoredReasons = null,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NavigationTiming);

        pub const Meta = struct {
            pub const name = "PerformanceNavigationTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const duration = bridge.accessor(NavigationTiming.getDuration, null, .{});
        pub const @"type" = bridge.property("navigate", .{ .template = false, .readonly = true });
        pub const redirectCount = bridge.property(0, .{ .template = false, .readonly = true });
        pub const unloadEventStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const unloadEventEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const workerStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const fetchStart = bridge.accessor(NavigationTiming.getFetchStart, null, .{});
        pub const domainLookupStart = bridge.accessor(NavigationTiming.getDomainLookupStart, null, .{});
        pub const domainLookupEnd = bridge.accessor(NavigationTiming.getDomainLookupEnd, null, .{});
        pub const connectStart = bridge.accessor(NavigationTiming.getConnectStart, null, .{});
        pub const secureConnectionStart = bridge.accessor(NavigationTiming.getSecureConnectionStart, null, .{});
        pub const connectEnd = bridge.accessor(NavigationTiming.getConnectEnd, null, .{});
        pub const requestStart = bridge.accessor(NavigationTiming.getRequestStart, null, .{});
        pub const responseStart = bridge.accessor(NavigationTiming.getResponseStart, null, .{});
        pub const responseEnd = bridge.accessor(NavigationTiming.getResponseEnd, null, .{});
        pub const domInteractive = bridge.accessor(NavigationTiming.getDomInteractive, null, .{});
        pub const domContentLoadedEventStart = bridge.accessor(NavigationTiming.getDomContentLoadedEventStart, null, .{});
        pub const domContentLoadedEventEnd = bridge.accessor(NavigationTiming.getDomContentLoadedEventEnd, null, .{});
        pub const domComplete = bridge.accessor(NavigationTiming.getDomComplete, null, .{});
        pub const loadEventStart = bridge.accessor(NavigationTiming.getLoadEventStart, null, .{});
        pub const loadEventEnd = bridge.accessor(NavigationTiming.getLoadEventEnd, null, .{});
        pub const nextHopProtocol = bridge.property("h2", .{ .template = false, .readonly = true });
        pub const transferSize = bridge.property(0, .{ .template = false, .readonly = true });
        pub const encodedBodySize = bridge.property(0, .{ .template = false, .readonly = true });
        pub const decodedBodySize = bridge.property(0, .{ .template = false, .readonly = true });
        pub const toJSON = bridge.function(NavigationTiming.toJSON, .{});
    };
};

/// PerformanceTiming — Navigation Timing Level 1 (legacy, but widely used).
/// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceTiming
/// Chrome-only `performance.memory`. Chrome quantizes these to 100 KB as a
/// Spectre mitigation, so a fixed triple is realistic; what detectors actually
/// flag is the property missing while the browser claims to be Chrome
/// (sannysoft's CHR_MEMORY). Window-only — Chrome does not expose it to
/// workers, and offering it there would be its own inconsistency.
pub const MemoryInfo = struct {
    // Padding to avoid zero-size struct pointer collisions.
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MemoryInfo);

        pub const Meta = struct {
            pub const name = "MemoryInfo";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const jsHeapSizeLimit = bridge.property(2172649472.0, .{ .template = false, .readonly = true });
        pub const totalJSHeapSize = bridge.property(10200000.0, .{ .template = false, .readonly = true });
        pub const usedJSHeapSize = bridge.property(8300000.0, .{ .template = false, .readonly = true });
    };
};

pub const PerformanceTiming = struct {
    navigation_start: f64 = 0,
    fetch_start: f64 = 0,
    domain_lookup_start: f64 = 0,
    domain_lookup_end: f64 = 0,
    connect_start: f64 = 0,
    connect_end: f64 = 0,
    secure_connection_start: f64 = 0,
    request_start: f64 = 0,
    response_start: f64 = 0,
    response_end: f64 = 0,
    dom_loading: f64 = 0,
    dom_interactive: f64 = 0,
    dom_content_loaded_event_start: f64 = 0,
    dom_content_loaded_event_end: f64 = 0,
    dom_complete: f64 = 0,
    load_event_start: f64 = 0,
    load_event_end: f64 = 0,

    fn init(epoch_ms: f64) PerformanceTiming {
        const start = @floor(epoch_ms);
        return .{
            .navigation_start = start,
            .fetch_start = start,
        };
    }

    fn markResponseStart(self: *PerformanceTiming, transfer_epoch_ms: f64, timing: NetworkTiming) void {
        if (self.response_start != 0) return;
        const start = @floor(transfer_epoch_ms);
        const phase = struct {
            fn at(base: f64, micros: i64) f64 {
                return @floor(base + @as(f64, @floatFromInt(@max(0, micros))) / 1000.0);
            }
        }.at;

        const request_start = phase(transfer_epoch_ms, timing.pre_transfer_micros);
        if (timing.connection_reused) {
            self.domain_lookup_start = request_start;
            self.domain_lookup_end = request_start;
            self.connect_start = request_start;
            self.secure_connection_start = request_start;
            self.connect_end = request_start;
        } else {
            self.domain_lookup_start = start;
            self.domain_lookup_end = phase(transfer_epoch_ms, timing.name_lookup_micros);
            self.connect_start = self.domain_lookup_end;
            self.secure_connection_start = phase(transfer_epoch_ms, timing.connect_micros);
            const connect_end_micros = if (timing.app_connect_micros > 0)
                timing.app_connect_micros
            else
                timing.connect_micros;
            self.connect_end = phase(transfer_epoch_ms, connect_end_micros);
        }
        self.request_start = @max(request_start, self.connect_end);
        self.response_start = @max(
            phase(transfer_epoch_ms, timing.start_transfer_micros),
            self.request_start,
        );
    }

    fn markResponseEnd(self: *PerformanceTiming, epoch_ms: f64, elapsed_ms: f64) void {
        const value = @floor(epoch_ms + elapsed_ms);
        self.response_end = value;
        self.dom_loading = value;
    }

    fn markDomContentLoaded(self: *PerformanceTiming, timestamp: f64) void {
        const value = @floor(timestamp);
        self.dom_interactive = value;
        self.dom_content_loaded_event_start = value;
        self.dom_content_loaded_event_end = value;
    }

    fn markLoadEventEnd(self: *PerformanceTiming, timestamp: f64) void {
        const value = @floor(timestamp);
        self.dom_complete = value;
        self.load_event_start = value;
        self.load_event_end = value;
    }

    pub fn getNavigationStart(self: *const PerformanceTiming) f64 {
        return self.navigation_start;
    }

    pub fn getFetchStart(self: *const PerformanceTiming) f64 {
        return self.fetch_start;
    }

    pub fn getDomainLookupStart(self: *const PerformanceTiming) f64 {
        return self.domain_lookup_start;
    }

    pub fn getDomainLookupEnd(self: *const PerformanceTiming) f64 {
        return self.domain_lookup_end;
    }

    pub fn getConnectStart(self: *const PerformanceTiming) f64 {
        return self.connect_start;
    }

    pub fn getConnectEnd(self: *const PerformanceTiming) f64 {
        return self.connect_end;
    }

    pub fn getSecureConnectionStart(self: *const PerformanceTiming) f64 {
        return self.secure_connection_start;
    }

    pub fn getRequestStart(self: *const PerformanceTiming) f64 {
        return self.request_start;
    }

    pub fn getResponseStart(self: *const PerformanceTiming) f64 {
        return self.response_start;
    }

    pub fn getResponseEnd(self: *const PerformanceTiming) f64 {
        return self.response_end;
    }

    pub fn getDomLoading(self: *const PerformanceTiming) f64 {
        return self.dom_loading;
    }

    pub fn getDomInteractive(self: *const PerformanceTiming) f64 {
        return self.dom_interactive;
    }

    pub fn getDomContentLoadedEventStart(self: *const PerformanceTiming) f64 {
        return self.dom_content_loaded_event_start;
    }

    pub fn getDomContentLoadedEventEnd(self: *const PerformanceTiming) f64 {
        return self.dom_content_loaded_event_end;
    }

    pub fn getDomComplete(self: *const PerformanceTiming) f64 {
        return self.dom_complete;
    }

    pub fn getLoadEventStart(self: *const PerformanceTiming) f64 {
        return self.load_event_start;
    }

    pub fn getLoadEventEnd(self: *const PerformanceTiming) f64 {
        return self.load_event_end;
    }

    pub fn toJSON(self: *const PerformanceTiming) struct {
        navigationStart: f64,
        unloadEventStart: f64,
        unloadEventEnd: f64,
        redirectStart: f64,
        redirectEnd: f64,
        fetchStart: f64,
        domainLookupStart: f64,
        domainLookupEnd: f64,
        connectStart: f64,
        connectEnd: f64,
        secureConnectionStart: f64,
        requestStart: f64,
        responseStart: f64,
        responseEnd: f64,
        domLoading: f64,
        domInteractive: f64,
        domContentLoadedEventStart: f64,
        domContentLoadedEventEnd: f64,
        domComplete: f64,
        loadEventStart: f64,
        loadEventEnd: f64,
    } {
        return .{
            .navigationStart = self.navigation_start,
            .unloadEventStart = 0,
            .unloadEventEnd = 0,
            .redirectStart = 0,
            .redirectEnd = 0,
            .fetchStart = self.fetch_start,
            .domainLookupStart = self.domain_lookup_start,
            .domainLookupEnd = self.domain_lookup_end,
            .connectStart = self.connect_start,
            .connectEnd = self.connect_end,
            .secureConnectionStart = self.secure_connection_start,
            .requestStart = self.request_start,
            .responseStart = self.response_start,
            .responseEnd = self.response_end,
            .domLoading = self.dom_loading,
            .domInteractive = self.dom_interactive,
            .domContentLoadedEventStart = self.dom_content_loaded_event_start,
            .domContentLoadedEventEnd = self.dom_content_loaded_event_end,
            .domComplete = self.dom_complete,
            .loadEventStart = self.load_event_start,
            .loadEventEnd = self.load_event_end,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceTiming);

        pub const Meta = struct {
            pub const name = "PerformanceTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const navigationStart = bridge.accessor(PerformanceTiming.getNavigationStart, null, .{});
        pub const unloadEventStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const unloadEventEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const fetchStart = bridge.accessor(PerformanceTiming.getFetchStart, null, .{});
        pub const domainLookupStart = bridge.accessor(PerformanceTiming.getDomainLookupStart, null, .{});
        pub const domainLookupEnd = bridge.accessor(PerformanceTiming.getDomainLookupEnd, null, .{});
        pub const connectStart = bridge.accessor(PerformanceTiming.getConnectStart, null, .{});
        pub const connectEnd = bridge.accessor(PerformanceTiming.getConnectEnd, null, .{});
        pub const secureConnectionStart = bridge.accessor(PerformanceTiming.getSecureConnectionStart, null, .{});
        pub const requestStart = bridge.accessor(PerformanceTiming.getRequestStart, null, .{});
        pub const responseStart = bridge.accessor(PerformanceTiming.getResponseStart, null, .{});
        pub const responseEnd = bridge.accessor(PerformanceTiming.getResponseEnd, null, .{});
        pub const domLoading = bridge.accessor(PerformanceTiming.getDomLoading, null, .{});
        pub const domInteractive = bridge.accessor(PerformanceTiming.getDomInteractive, null, .{});
        pub const domContentLoadedEventStart = bridge.accessor(PerformanceTiming.getDomContentLoadedEventStart, null, .{});
        pub const domContentLoadedEventEnd = bridge.accessor(PerformanceTiming.getDomContentLoadedEventEnd, null, .{});
        pub const domComplete = bridge.accessor(PerformanceTiming.getDomComplete, null, .{});
        pub const loadEventStart = bridge.accessor(PerformanceTiming.getLoadEventStart, null, .{});
        pub const loadEventEnd = bridge.accessor(PerformanceTiming.getLoadEventEnd, null, .{});
        pub const toJSON = bridge.function(PerformanceTiming.toJSON, .{});
    };
};

// PerformanceNavigation implements the Navigation Timing Level 1 API.
// https://www.w3.org/TR/navigation-timing/#sec-navigation-navigation-timing-interface
// Stub implementation — returns 0 for type (TYPE_NAVIGATE) and 0 for redirectCount.
pub const PerformanceNavigation = struct {
    // Padding to avoid zero-size struct, which causes identity_map pointer collisions.
    _pad: bool = false,

    pub fn toJSON(_: *const PerformanceNavigation) struct {
        type: u32,
        redirectCount: u32,
    } {
        return .{ .type = 0, .redirectCount = 0 };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceNavigation);

        pub const Meta = struct {
            pub const name = "PerformanceNavigation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectCount = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const TYPE_NAVIGATE = bridge.property(0, .{ .template = false, .readonly = true });
        pub const TYPE_RELOAD = bridge.property(1, .{ .template = false, .readonly = true });
        pub const TYPE_BACK_FORWARD = bridge.property(2, .{ .template = false, .readonly = true });
        pub const TYPE_RESERVED = bridge.property(255, .{ .template = false, .readonly = true });
        pub const toJSON = bridge.function(PerformanceNavigation.toJSON, .{});
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Performance" {
    try testing.htmlRunner("performance.html", .{});
}
