// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

const js = @import("../js/js.zig");

const ContentIndex = @This();

_pad: bool = false,

pub const JsApi = struct {
    pub const bridge = js.Bridge(ContentIndex);

    pub const Meta = struct {
        pub const name = "ContentIndex";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };
};
