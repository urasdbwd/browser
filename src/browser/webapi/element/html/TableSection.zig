const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Node = @import("../../Node.zig");
const Frame = @import("../../../Frame.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const collections = @import("../../collections.zig");
const Table = @import("Table.zig");

const String = lp.String;

const TableSection = @This();

pub const Proto = HtmlElement;

_tag_name: String,
_tag: Element.Tag,
_proto: *HtmlElement,

pub fn asElement(self: *TableSection) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *TableSection) *Node {
    return self.asElement().asNode();
}

pub fn getRows(self: *TableSection, frame: *Frame) collections.NodeLive(.child_tag) {
    return collections.NodeLive(.child_tag).init(self.asNode(), .tr, frame);
}

pub fn insertRow(self: *TableSection, index: ?i32, frame: *Frame) !*Element {
    return Table.insertChildAt(self.asNode(), .row, index, frame);
}

pub fn deleteRow(self: *TableSection, index: i32, frame: *Frame) !void {
    return Table.deleteChildAt(self.asNode(), .row, index, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TableSection);

    pub const Meta = struct {
        pub const name = "HTMLTableSectionElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const rows = bridge.accessor(TableSection.getRows, null, .{});
    pub const insertRow = bridge.function(TableSection.insertRow, .{ .ce_reactions = true });
    pub const deleteRow = bridge.function(TableSection.deleteRow, .{ .ce_reactions = true });
};
