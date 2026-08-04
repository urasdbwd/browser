const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");

const Table = @This();

pub const Proto = HtmlElement;

_proto: *HtmlElement,

pub fn asElement(self: *Table) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *Table) *Node {
    return self.asElement().asNode();
}

pub fn getTBodies(self: *Table, frame: *Frame) collections.NodeLive(.child_tag) {
    return collections.NodeLive(.child_tag).init(self.asNode(), .tbody, frame);
}

pub fn insertRow(self: *Table, index_: ?i32, frame: *Frame) !*Element {
    const index = index_ orelse -1;
    if (index < -1) {
        return error.IndexSizeError;
    }

    var scan: RowScan = .{ .index = index };
    const before = self.scanRows(&scan);

    const row = try Frame.node_factory.createElementNS(frame, .html, "tr", null);
    if (index >= 0) {
        if (before) |ref| {
            _ = try ref.parentNode().?.insertBefore(row, ref, frame);
            return row.is(Element).?;
        }
        if (index != scan.count) {
            return error.IndexSizeError;
        }
    }

    // Appending: into the last row's section, else the last tbody, else a
    // tbody we have to create (spec: "if there are no rows and no tbody").
    const parent = blk: {
        if (scan.last) |last| {
            break :blk last.parentNode().?;
        }
        var it = self.asNode().childrenIterator();
        var tbody: ?*Node = null;
        while (it.next()) |child| {
            const el = child.is(Element) orelse continue;
            if (el.getTag() == .tbody) {
                tbody = child;
            }
        }
        if (tbody) |t| {
            break :blk t;
        }
        const created = try Frame.node_factory.createElementNS(frame, .html, "tbody", null);
        _ = try self.asNode().appendChild(created, frame);
        break :blk created;
    };
    _ = try parent.appendChild(row, frame);
    return row.is(Element).?;
}

pub fn deleteRow(self: *Table, index: i32, frame: *Frame) !void {
    if (index < -1) {
        return error.IndexSizeError;
    }
    const row = self.findRow(index) orelse {
        if (index == -1) {
            // deleteRow(-1) on a rowless table is a no-op.
            return;
        }
        return error.IndexSizeError;
    };
    _ = try row.parentNode().?.removeChild(row, frame);
}

// Finds the index-th row (or the last row for -1) in spec order: thead, tr,
// tbody then tfoot
fn findRow(self: *Table, index: i32) ?*Node {
    var scan: RowScan = .{ .index = index };
    return self.scanRows(&scan);
}

// Same walk as findRow, but leaves the scan behind so insertRow can read the
// row count and the last row it saw.
fn scanRows(self: *Table, scan: *RowScan) ?*Node {
    if (self.scanSectionRows(.thead, scan)) |row| {
        return row;
    }

    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        switch (el.getTag()) {
            .tr => if (scan.check(child)) |row| {
                return row;
            },
            .tbody => if (scanChildRows(child, scan)) |row| {
                return row;
            },
            else => {},
        }
    }

    if (self.scanSectionRows(.tfoot, scan)) |row| {
        return row;
    }
    if (scan.index == -1) {
        return scan.last;
    }
    return null;
}

const RowScan = struct {
    index: i32,
    count: i32 = 0,
    last: ?*Node = null,

    fn check(self: *RowScan, row: *Node) ?*Node {
        if (self.count == self.index) {
            return row;
        }
        self.count += 1;
        self.last = row;
        return null;
    }
};

fn scanSectionRows(self: *Table, tag: Element.Tag, scan: *RowScan) ?*Node {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (el.getTag() != tag) {
            continue;
        }
        if (scanChildRows(child, scan)) |row| {
            return row;
        }
    }
    return null;
}

fn scanChildRows(section: *Node, scan: *RowScan) ?*Node {
    var it = section.childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (el.getTag() == .tr) {
            if (scan.check(child)) |row| {
                return row;
            }
        }
    }
    return null;
}

// <thead>/<tbody>/<tfoot>.insertRow and <tr>.insertCell are the same operation
// over a different child tag, so they share this.
pub const ChildKind = enum {
    row,
    cell,

    fn matches(self: ChildKind, el: *Element) bool {
        return switch (self) {
            .row => el.getTag() == .tr,
            .cell => el.getTag() == .td or el.getTag() == .th,
        };
    }

    fn tagName(self: ChildKind) []const u8 {
        return switch (self) {
            .row => "tr",
            .cell => "td",
        };
    }
};

pub fn insertChildAt(parent: *Node, kind: ChildKind, index_: ?i32, frame: *Frame) !*Element {
    const index = index_ orelse -1;
    if (index < -1) {
        return error.IndexSizeError;
    }

    var count: i32 = 0;
    var before: ?*Node = null;
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (kind.matches(el) == false) {
            continue;
        }
        if (count == index) {
            before = child;
            break;
        }
        count += 1;
    }
    if (before == null and index > count) {
        return error.IndexSizeError;
    }

    const node = try Frame.node_factory.createElementNS(frame, .html, kind.tagName(), null);
    if (before) |ref| {
        _ = try parent.insertBefore(node, ref, frame);
    } else {
        _ = try parent.appendChild(node, frame);
    }
    return node.is(Element).?;
}

pub fn deleteChildAt(parent: *Node, kind: ChildKind, index: i32, frame: *Frame) !void {
    if (index < -1) {
        return error.IndexSizeError;
    }

    var count: i32 = 0;
    var last: ?*Node = null;
    var target: ?*Node = null;
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        const el = child.is(Element) orelse continue;
        if (kind.matches(el) == false) {
            continue;
        }
        if (count == index) {
            target = child;
            break;
        }
        count += 1;
        last = child;
    }

    const node = target orelse blk: {
        // deleteRow(-1)/deleteCell(-1) removes the last one, or is a no-op.
        if (index == -1) {
            break :blk last orelse return;
        }
        return error.IndexSizeError;
    };
    _ = try parent.removeChild(node, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Table);

    pub const Meta = struct {
        pub const name = "HTMLTableElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const tBodies = bridge.accessor(Table.getTBodies, null, .{});
    pub const insertRow = bridge.function(Table.insertRow, .{ .ce_reactions = true });
    pub const deleteRow = bridge.function(Table.deleteRow, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Table" {
    try testing.htmlRunner("element/html/table.html", .{});
}
