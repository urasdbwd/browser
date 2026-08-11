// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

pub fn registerTypes() []const type {
    return &.{ TrustedTypePolicyFactory, TrustedTypePolicy, TrustedHTML, TrustedScript, TrustedScriptURL };
}

pub const TrustedTypePolicyFactory = struct {
    _empty_html: ?*TrustedHTML = null,
    _empty_script: ?*TrustedScript = null,

    const PolicyOptions = struct {
        createHTML: ?js.Function = null,
        createScript: ?js.Function = null,
        createScriptURL: ?js.Function = null,
    };

    pub fn createPolicy(
        _: *TrustedTypePolicyFactory,
        name: []const u8,
        options: PolicyOptions,
        exec: *js.Execution,
    ) !*TrustedTypePolicy {
        const arena = try exec.getArena(.small, "TrustedTypePolicy");
        errdefer arena.release();

        const policy = try arena.create(TrustedTypePolicy);
        policy.* = .{
            ._arena = arena,
            ._name = try arena.dupe(u8, name),
            ._create_html = if (options.createHTML) |callback| try callback.persist() else null,
            ._create_script = if (options.createScript) |callback| try callback.persist() else null,
            ._create_script_url = if (options.createScriptURL) |callback| try callback.persist() else null,
        };
        return policy;
    }

    pub fn isHTML(_: *const TrustedTypePolicyFactory, value: js.Value) bool {
        _ = value.toZig(*TrustedHTML) catch return false;
        return true;
    }

    pub fn isScript(_: *const TrustedTypePolicyFactory, value: js.Value) bool {
        _ = value.toZig(*TrustedScript) catch return false;
        return true;
    }

    pub fn isScriptURL(_: *const TrustedTypePolicyFactory, value: js.Value) bool {
        _ = value.toZig(*TrustedScriptURL) catch return false;
        return true;
    }

    pub fn getEmptyHTML(self: *TrustedTypePolicyFactory, exec: *const js.Execution) !*TrustedHTML {
        if (self._empty_html) |value| return value;

        const value = try exec.arena.create(TrustedHTML);
        value.* = .{};
        self._empty_html = value;
        return value;
    }

    pub fn getEmptyScript(self: *TrustedTypePolicyFactory, exec: *const js.Execution) !*TrustedScript {
        if (self._empty_script) |value| return value;

        const value = try exec.arena.create(TrustedScript);
        value.* = .{};
        self._empty_script = value;
        return value;
    }

    pub fn getDefaultPolicy(_: *const TrustedTypePolicyFactory) ?*TrustedTypePolicy {
        return null;
    }

    pub fn getType(_: *const TrustedTypePolicyFactory) ?[]const u8 {
        return null;
    }

    pub fn getTypeMapping(_: *const TrustedTypePolicyFactory, exec: *const js.Execution) js.Object {
        return exec.js.local.?.newObject();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TrustedTypePolicyFactory);

        pub const Meta = struct {
            pub const name = "TrustedTypePolicyFactory";
            pub const no_interface_object = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const emptyHTML = bridge.accessor(TrustedTypePolicyFactory.getEmptyHTML, null, .{});
        pub const emptyScript = bridge.accessor(TrustedTypePolicyFactory.getEmptyScript, null, .{});
        pub const defaultPolicy = bridge.accessor(TrustedTypePolicyFactory.getDefaultPolicy, null, .{});
        pub const createPolicy = bridge.function(TrustedTypePolicyFactory.createPolicy, .{});
        pub const getAttributeType = bridge.function(TrustedTypePolicyFactory.getType, .{});
        pub const getPropertyType = bridge.function(TrustedTypePolicyFactory.getType, .{});
        pub const getTypeMapping = bridge.function(TrustedTypePolicyFactory.getTypeMapping, .{});
        pub const isHTML = bridge.function(TrustedTypePolicyFactory.isHTML, .{});
        pub const isScript = bridge.function(TrustedTypePolicyFactory.isScript, .{});
        pub const isScriptURL = bridge.function(TrustedTypePolicyFactory.isScriptURL, .{});
    };
};

pub const TrustedTypePolicy = struct {
    _rc: lp.RC = .{},
    _arena: *lp.Arena,
    _name: []const u8,
    _create_html: ?js.Function.Global,
    _create_script: ?js.Function.Global,
    _create_script_url: ?js.Function.Global,

    pub fn acquireRef(self: *TrustedTypePolicy) void {
        self._rc.acquire();
    }

    pub fn releaseRef(self: *TrustedTypePolicy, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn deinit(self: *TrustedTypePolicy, _: *Page) void {
        if (self._create_html) |callback| callback.release();
        if (self._create_script) |callback| callback.release();
        if (self._create_script_url) |callback| callback.release();
        self._arena.release();
    }

    pub fn getName(self: *const TrustedTypePolicy) []const u8 {
        return self._name;
    }

    fn call(callback: ?js.Function.Global, input: js.Value, exec: *js.Execution) !js.Value {
        const function = callback orelse return error.TypeError;
        return exec.js.toLocal(function).callRethrow(js.Value, .{input});
    }

    pub fn createHTML(self: *TrustedTypePolicy, input: js.Value, exec: *js.Execution) !*TrustedHTML {
        const value = try call(self._create_html, input, exec);
        const trusted = try self._arena.create(TrustedHTML);
        trusted.* = .{ ._value = try self._arena.dupe(u8, try value.toZig([]const u8)) };
        return trusted;
    }

    pub fn createScript(self: *TrustedTypePolicy, input: js.Value, exec: *js.Execution) !*TrustedScript {
        const value = try call(self._create_script, input, exec);
        const trusted = try self._arena.create(TrustedScript);
        trusted.* = .{ ._value = try self._arena.dupe(u8, try value.toZig([]const u8)) };
        return trusted;
    }

    pub fn createScriptURL(self: *TrustedTypePolicy, input: js.Value, exec: *js.Execution) !*TrustedScriptURL {
        const value = try call(self._create_script_url, input, exec);
        const trusted = try self._arena.create(TrustedScriptURL);
        trusted.* = .{ ._value = try self._arena.dupe(u8, try value.toZig([]const u8)) };
        return trusted;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TrustedTypePolicy);

        pub const Meta = struct {
            pub const name = "TrustedTypePolicy";
            pub const no_interface_object = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(TrustedTypePolicy.getName, null, .{});
        pub const createHTML = bridge.function(TrustedTypePolicy.createHTML, .{});
        pub const createScript = bridge.function(TrustedTypePolicy.createScript, .{});
        pub const createScriptURL = bridge.function(TrustedTypePolicy.createScriptURL, .{});
    };
};

fn TrustedValue(comptime interface_name: []const u8) type {
    return struct {
        const Self = @This();

        _value: []const u8 = "",

        pub fn toString(self: *const Self) []const u8 {
            return self._value;
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = interface_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const toJSON = bridge.function(Self.toString, .{});
            pub const toString = bridge.function(Self.toString, .{});
        };
    };
}

pub const TrustedHTML = TrustedValue("TrustedHTML");
pub const TrustedScript = TrustedValue("TrustedScript");
pub const TrustedScriptURL = TrustedValue("TrustedScriptURL");

const testing = @import("../../testing.zig");
test "WebApi: TrustedTypes" {
    try testing.htmlRunner("trusted_types.html", .{});
}
