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

const std = @import("std");
const js = @import("../../js/js.zig");

const Element = @import("../Element.zig");
const Frame = @import("../../Frame.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");

const CSSStyleProperties = @This();

pub const Proto = CSSStyleDeclaration;

_proto: *CSSStyleDeclaration,

pub fn init(element: ?*Element, is_computed: bool, frame: *Frame) !*CSSStyleProperties {
    const self = try frame._factory.chained(.{
        CSSStyleDeclaration{
            ._element = element,
            ._is_computed = is_computed,
        },
        CSSStyleProperties{ ._proto = undefined },
    });
    try self._proto.parseInlineStyle(frame);
    return self;
}

pub fn asCSSStyleDeclaration(self: *CSSStyleProperties) *CSSStyleDeclaration {
    return self._proto;
}

fn ruleCssText(self: *CSSStyleProperties, frame: *Frame) !?[]const u8 {
    if (self._proto._element != null or self._proto._is_computed) return null;
    return try self._proto.getCssText(frame);
}

fn ruleStyleChanged(self: *CSSStyleProperties, before: ?[]const u8, frame: *Frame) !void {
    const previous = before orelse return;
    const current = try self._proto.getCssText(frame);
    if (std.mem.eql(u8, previous, current)) return;
    frame._style_manager.sheetModified();
    frame.snapshotChanged();
}

pub fn setNamed(self: *CSSStyleProperties, name: []const u8, value: []const u8, frame: *Frame) !void {
    if (method_names.has(name)) {
        return error.NotHandled;
    }
    const before = try self.ruleCssText(frame);
    const dash_case = camelCaseToDashCase(name, &frame.buf);
    try self._proto.setProperty(dash_case, value, null, frame);
    try self.ruleStyleChanged(before, frame);
}

pub fn getCssText(self: *const CSSStyleProperties, frame: *Frame) ![]const u8 {
    return self._proto.getCssText(frame);
}

fn getLength(self: *const CSSStyleProperties) u32 {
    return self._proto.length();
}

fn getParentRule(_: *const CSSStyleProperties) ?[]const u8 {
    return null;
}

fn getPropertyPriority(self: *const CSSStyleProperties, property_name: []const u8, frame: *Frame) []const u8 {
    return self._proto.getPropertyPriority(property_name, frame);
}

fn getPropertyValue(self: *const CSSStyleProperties, property_name: []const u8, frame: *Frame) []const u8 {
    return self._proto.getPropertyValue(property_name, frame);
}

fn item(self: *const CSSStyleProperties, index: i32) []const u8 {
    if (index < 0) return "";
    return self._proto.item(@intCast(index));
}

pub fn setCssText(self: *CSSStyleProperties, text: []const u8, frame: *Frame) !void {
    const before = try self.ruleCssText(frame);
    try self._proto.setCssText(text, frame);
    try self.ruleStyleChanged(before, frame);
}

pub fn setProperty(self: *CSSStyleProperties, property_name: []const u8, value: []const u8, priority: ?[]const u8, frame: *Frame) !void {
    const before = try self.ruleCssText(frame);
    try self._proto.setProperty(property_name, value, priority, frame);
    try self.ruleStyleChanged(before, frame);
}

pub fn removeProperty(self: *CSSStyleProperties, property_name: []const u8, frame: *Frame) ![]const u8 {
    const before = try self.ruleCssText(frame);
    const removed = try self._proto.removeProperty(property_name, frame);
    try self.ruleStyleChanged(before, frame);
    return removed;
}

pub fn getFloat(self: *const CSSStyleProperties, frame: *Frame) []const u8 {
    return self._proto.getFloat(frame);
}

pub fn setFloat(self: *CSSStyleProperties, value: ?[]const u8, frame: *Frame) !void {
    const before = try self.ruleCssText(frame);
    try self._proto.setFloat(value, frame);
    try self.ruleStyleChanged(before, frame);
}

pub fn getNamed(self: *CSSStyleProperties, name: []const u8, frame: *Frame) ![]const u8 {
    if (method_names.has(name)) {
        return error.NotHandled;
    }

    const dash_case = camelCaseToDashCase(name, &frame.buf);

    // Only apply vendor prefix filtering for camelCase access (no dashes in input)
    // Bracket notation with dash-case (e.g., div.style['-moz-user-select']) should return the actual value
    const is_camelcase_access = std.mem.indexOfScalar(u8, name, '-') == null;
    if (is_camelcase_access and std.mem.startsWith(u8, dash_case, "-")) {
        // We only support -webkit-, other vendor prefixes return undefined for camelCase access
        const is_webkit = std.mem.startsWith(u8, dash_case, "-webkit-");
        const is_moz = std.mem.startsWith(u8, dash_case, "-moz-");
        const is_ms = std.mem.startsWith(u8, dash_case, "-ms-");
        const is_o = std.mem.startsWith(u8, dash_case, "-o-");

        if ((is_moz or is_ms or is_o) and !is_webkit) {
            return error.NotHandled;
        }
    }

    const value = self._proto.getPropertyValue(dash_case, frame);

    // Property accessors have special handling for empty values:
    // - Known CSS properties return '' when not set
    // - Vendor-prefixed properties return undefined when not set
    // - Unknown properties return undefined
    if (value.len == 0) {
        // Unsupported vendor-prefixed properties return undefined when not set.
        if (std.mem.startsWith(u8, dash_case, "-") and !isSupportedPropertyName(name)) {
            return error.NotHandled;
        }

        // Known CSS properties return '', unknown properties return undefined
        if (!isKnownCSSProperty(dash_case) and !isSupportedPropertyName(name)) {
            return error.NotHandled;
        }

        return "";
    }

    return value;
}

fn isKnownCSSProperty(dash_case: []const u8) bool {
    const known_properties = std.StaticStringMap(void).initComptime(.{
        // Colors & backgrounds
        .{ "color", {} },
        .{ "background", {} },
        .{ "background-color", {} },
        .{ "background-image", {} },
        .{ "background-position", {} },
        .{ "background-repeat", {} },
        .{ "background-size", {} },
        .{ "background-attachment", {} },
        .{ "background-clip", {} },
        .{ "background-origin", {} },
        // Typography
        .{ "font", {} },
        .{ "font-family", {} },
        .{ "font-size", {} },
        .{ "font-style", {} },
        .{ "font-weight", {} },
        .{ "font-variant", {} },
        .{ "line-height", {} },
        .{ "letter-spacing", {} },
        .{ "word-spacing", {} },
        .{ "text-align", {} },
        .{ "text-decoration", {} },
        .{ "text-indent", {} },
        .{ "text-transform", {} },
        .{ "white-space", {} },
        .{ "word-break", {} },
        .{ "word-wrap", {} },
        .{ "overflow-wrap", {} },
        // Box model
        .{ "margin", {} },
        .{ "margin-top", {} },
        .{ "margin-right", {} },
        .{ "margin-bottom", {} },
        .{ "margin-left", {} },
        .{ "margin-block", {} },
        .{ "margin-block-start", {} },
        .{ "margin-block-end", {} },
        .{ "margin-inline", {} },
        .{ "margin-inline-start", {} },
        .{ "margin-inline-end", {} },
        .{ "padding", {} },
        .{ "padding-top", {} },
        .{ "padding-right", {} },
        .{ "padding-bottom", {} },
        .{ "padding-left", {} },
        .{ "padding-block", {} },
        .{ "padding-block-start", {} },
        .{ "padding-block-end", {} },
        .{ "padding-inline", {} },
        .{ "padding-inline-start", {} },
        .{ "padding-inline-end", {} },
        // Border
        .{ "border", {} },
        .{ "border-width", {} },
        .{ "border-style", {} },
        .{ "border-color", {} },
        .{ "border-top", {} },
        .{ "border-top-width", {} },
        .{ "border-top-style", {} },
        .{ "border-top-color", {} },
        .{ "border-right", {} },
        .{ "border-right-width", {} },
        .{ "border-right-style", {} },
        .{ "border-right-color", {} },
        .{ "border-bottom", {} },
        .{ "border-bottom-width", {} },
        .{ "border-bottom-style", {} },
        .{ "border-bottom-color", {} },
        .{ "border-left", {} },
        .{ "border-left-width", {} },
        .{ "border-left-style", {} },
        .{ "border-left-color", {} },
        .{ "border-radius", {} },
        .{ "border-top-left-radius", {} },
        .{ "border-top-right-radius", {} },
        .{ "border-bottom-left-radius", {} },
        .{ "border-bottom-right-radius", {} },
        .{ "border-collapse", {} },
        .{ "border-spacing", {} },
        // Sizing
        .{ "width", {} },
        .{ "height", {} },
        .{ "min-width", {} },
        .{ "min-height", {} },
        .{ "max-width", {} },
        .{ "max-height", {} },
        .{ "box-sizing", {} },
        // Positioning
        .{ "position", {} },
        .{ "top", {} },
        .{ "right", {} },
        .{ "bottom", {} },
        .{ "left", {} },
        .{ "inset", {} },
        .{ "inset-block", {} },
        .{ "inset-block-start", {} },
        .{ "inset-block-end", {} },
        .{ "inset-inline", {} },
        .{ "inset-inline-start", {} },
        .{ "inset-inline-end", {} },
        .{ "z-index", {} },
        .{ "float", {} },
        .{ "clear", {} },
        // Display & visibility
        .{ "display", {} },
        .{ "visibility", {} },
        .{ "opacity", {} },
        .{ "overflow", {} },
        .{ "overflow-x", {} },
        .{ "overflow-y", {} },
        .{ "clip", {} },
        .{ "clip-path", {} },
        // Flexbox
        .{ "flex", {} },
        .{ "flex-direction", {} },
        .{ "flex-wrap", {} },
        .{ "flex-flow", {} },
        .{ "flex-grow", {} },
        .{ "flex-shrink", {} },
        .{ "flex-basis", {} },
        .{ "order", {} },
        // Grid
        .{ "grid", {} },
        .{ "grid-template", {} },
        .{ "grid-template-columns", {} },
        .{ "grid-template-rows", {} },
        .{ "grid-template-areas", {} },
        .{ "grid-auto-columns", {} },
        .{ "grid-auto-rows", {} },
        .{ "grid-auto-flow", {} },
        .{ "grid-column", {} },
        .{ "grid-column-start", {} },
        .{ "grid-column-end", {} },
        .{ "grid-row", {} },
        .{ "grid-row-start", {} },
        .{ "grid-row-end", {} },
        .{ "grid-area", {} },
        .{ "gap", {} },
        .{ "row-gap", {} },
        .{ "column-gap", {} },
        // Alignment (flexbox & grid)
        .{ "align-content", {} },
        .{ "align-items", {} },
        .{ "align-self", {} },
        .{ "justify-content", {} },
        .{ "justify-items", {} },
        .{ "justify-self", {} },
        .{ "place-content", {} },
        .{ "place-items", {} },
        .{ "place-self", {} },
        // Transforms & animations
        .{ "transform", {} },
        .{ "transform-origin", {} },
        .{ "transform-style", {} },
        .{ "perspective", {} },
        .{ "perspective-origin", {} },
        .{ "transition", {} },
        .{ "transition-property", {} },
        .{ "transition-duration", {} },
        .{ "transition-timing-function", {} },
        .{ "transition-delay", {} },
        .{ "animation", {} },
        .{ "animation-duration", {} },
        .{ "animation-timing-function", {} },
        .{ "animation-delay", {} },
        .{ "animation-iteration-count", {} },
        .{ "animation-direction", {} },
        .{ "animation-fill-mode", {} },
        .{ "animation-play-state", {} },
        // Filters & effects
        .{ "filter", {} },
        .{ "backdrop-filter", {} },
        .{ "box-shadow", {} },
        .{ "text-shadow", {} },
        // Outline
        .{ "outline", {} },
        .{ "outline-width", {} },
        .{ "outline-style", {} },
        .{ "outline-color", {} },
        .{ "outline-offset", {} },
        // Lists
        .{ "list-style", {} },
        .{ "list-style-type", {} },
        .{ "list-style-position", {} },
        .{ "list-style-image", {} },
        // Tables
        .{ "table-layout", {} },
        .{ "caption-side", {} },
        .{ "empty-cells", {} },
        // Misc
        .{ "cursor", {} },
        .{ "pointer-events", {} },
        .{ "user-select", {} },
        .{ "resize", {} },
        .{ "object-fit", {} },
        .{ "object-position", {} },
        .{ "vertical-align", {} },
        .{ "content", {} },
        .{ "quotes", {} },
        .{ "counter-reset", {} },
        .{ "counter-increment", {} },
        // Scrolling
        .{ "scroll-behavior", {} },
        .{ "scroll-margin", {} },
        .{ "scroll-padding", {} },
        .{ "overscroll-behavior", {} },
        .{ "overscroll-behavior-x", {} },
        .{ "overscroll-behavior-y", {} },
        // Containment
        .{ "contain", {} },
        .{ "contain-intrinsic-width", {} },
        .{ "container", {} },
        .{ "container-type", {} },
        .{ "container-name", {} },
        // Aspect ratio
        .{ "aspect-ratio", {} },
    });

    return known_properties.has(dash_case);
}

fn camelCaseToDashCase(name: []const u8, buf: []u8) []const u8 {
    if (name.len == 0) {
        return name;
    }

    // Special case: cssFloat -> float
    const lower_name = std.ascii.lowerString(buf, name);
    if (std.mem.eql(u8, lower_name, "cssfloat")) {
        return "float";
    }

    // If already contains dashes, just return lowercased
    if (std.mem.indexOfScalar(u8, name, '-')) |_| {
        return lower_name;
    }

    // Check if this looks like proper camelCase (starts with lowercase)
    // If not (e.g. "COLOR", "BackgroundColor"), just lowercase it
    if (name.len == 0 or !std.ascii.isLower(name[0])) {
        return lower_name;
    }

    // Check for vendor prefixes: webkitTransform -> -webkit-transform
    // Must have uppercase letter after the prefix
    const has_vendor_prefix = blk: {
        if (name.len > 6 and std.mem.startsWith(u8, name, "webkit") and std.ascii.isUpper(name[6])) break :blk true;
        if (name.len > 3 and std.mem.startsWith(u8, name, "moz") and std.ascii.isUpper(name[3])) break :blk true;
        if (name.len > 2 and std.mem.startsWith(u8, name, "ms") and std.ascii.isUpper(name[2])) break :blk true;
        if (name.len > 1 and std.mem.startsWith(u8, name, "o") and std.ascii.isUpper(name[1])) break :blk true;
        break :blk false;
    };

    var write_pos: usize = 0;

    if (has_vendor_prefix) {
        buf[write_pos] = '-';
        write_pos += 1;
    }

    for (name, 0..) |c, i| {
        if (write_pos >= buf.len) {
            return lower_name;
        }

        if (std.ascii.isUpper(c)) {
            const skip_dash = has_vendor_prefix and i < 10 and write_pos == 1;

            if (i > 0 and !skip_dash) {
                if (write_pos >= buf.len) break;
                buf[write_pos] = '-';
                write_pos += 1;
            }
            if (write_pos >= buf.len) break;
            buf[write_pos] = std.ascii.toLower(c);
            write_pos += 1;
        } else {
            buf[write_pos] = c;
            write_pos += 1;
        }
    }

    return buf[0..write_pos];
}

const method_names = std.StaticStringMap(void).initComptime(.{
    .{ "getPropertyValue", {} },
    .{ "setProperty", {} },
    .{ "removeProperty", {} },
    .{ "getPropertyPriority", {} },
    .{ "item", {} },
    .{ "cssText", {} },
    .{ "length", {} },
});

// Chromium exposes supported CSS declarations as enumerable own properties.
// Keep this list in the same order as Chrome 151 because reflection preserves it.
const supported_property_names = [_][]const u8{
    "accentColor",
    "additiveSymbols",
    "alignContent",
    "alignItems",
    "alignSelf",
    "alignmentBaseline",
    "all",
    "anchorName",
    "anchorScope",
    "animation",
    "animationComposition",
    "animationDelay",
    "animationDirection",
    "animationDuration",
    "animationFillMode",
    "animationIterationCount",
    "animationName",
    "animationPlayState",
    "animationRange",
    "animationRangeEnd",
    "animationRangeStart",
    "animationTimeline",
    "animationTimingFunction",
    "animationTrigger",
    "appRegion",
    "appearance",
    "ascentOverride",
    "aspectRatio",
    "backdropFilter",
    "backfaceVisibility",
    "background",
    "backgroundAttachment",
    "backgroundBlendMode",
    "backgroundClip",
    "backgroundColor",
    "backgroundImage",
    "backgroundOrigin",
    "backgroundPosition",
    "backgroundPositionX",
    "backgroundPositionY",
    "backgroundRepeat",
    "backgroundSize",
    "basePalette",
    "baselineShift",
    "baselineSource",
    "blockSize",
    "border",
    "borderBlock",
    "borderBlockColor",
    "borderBlockEnd",
    "borderBlockEndColor",
    "borderBlockEndStyle",
    "borderBlockEndWidth",
    "borderBlockStart",
    "borderBlockStartColor",
    "borderBlockStartStyle",
    "borderBlockStartWidth",
    "borderBlockStyle",
    "borderBlockWidth",
    "borderBottom",
    "borderBottomColor",
    "borderBottomLeftRadius",
    "borderBottomRightRadius",
    "borderBottomStyle",
    "borderBottomWidth",
    "borderCollapse",
    "borderColor",
    "borderEndEndRadius",
    "borderEndStartRadius",
    "borderImage",
    "borderImageOutset",
    "borderImageRepeat",
    "borderImageSlice",
    "borderImageSource",
    "borderImageWidth",
    "borderInline",
    "borderInlineColor",
    "borderInlineEnd",
    "borderInlineEndColor",
    "borderInlineEndStyle",
    "borderInlineEndWidth",
    "borderInlineStart",
    "borderInlineStartColor",
    "borderInlineStartStyle",
    "borderInlineStartWidth",
    "borderInlineStyle",
    "borderInlineWidth",
    "borderLeft",
    "borderLeftColor",
    "borderLeftStyle",
    "borderLeftWidth",
    "borderRadius",
    "borderRight",
    "borderRightColor",
    "borderRightStyle",
    "borderRightWidth",
    "borderShape",
    "borderSpacing",
    "borderStartEndRadius",
    "borderStartStartRadius",
    "borderStyle",
    "borderTop",
    "borderTopColor",
    "borderTopLeftRadius",
    "borderTopRightRadius",
    "borderTopStyle",
    "borderTopWidth",
    "borderWidth",
    "bottom",
    "boxDecorationBreak",
    "boxShadow",
    "boxSizing",
    "breakAfter",
    "breakBefore",
    "breakInside",
    "bufferedRendering",
    "captionSide",
    "caretAnimation",
    "caretColor",
    "caretShape",
    "clear",
    "clip",
    "clipPath",
    "clipRule",
    "color",
    "colorInterpolation",
    "colorInterpolationFilters",
    "colorRendering",
    "colorScheme",
    "columnCount",
    "columnFill",
    "columnGap",
    "columnHeight",
    "columnRule",
    "columnRuleBreak",
    "columnRuleColor",
    "columnRuleInset",
    "columnRuleInsetCap",
    "columnRuleInsetCapEnd",
    "columnRuleInsetCapStart",
    "columnRuleInsetEnd",
    "columnRuleInsetJunction",
    "columnRuleInsetJunctionEnd",
    "columnRuleInsetJunctionStart",
    "columnRuleInsetStart",
    "columnRuleStyle",
    "columnRuleVisibilityItems",
    "columnRuleWidth",
    "columnSpan",
    "columnWidth",
    "columnWrap",
    "columns",
    "contain",
    "containIntrinsicBlockSize",
    "containIntrinsicHeight",
    "containIntrinsicInlineSize",
    "containIntrinsicSize",
    "containIntrinsicWidth",
    "container",
    "containerName",
    "containerType",
    "content",
    "contentVisibility",
    "cornerBlockEndShape",
    "cornerBlockStartShape",
    "cornerBottomLeftShape",
    "cornerBottomRightShape",
    "cornerBottomShape",
    "cornerEndEndShape",
    "cornerEndStartShape",
    "cornerInlineEndShape",
    "cornerInlineStartShape",
    "cornerLeftShape",
    "cornerRightShape",
    "cornerShape",
    "cornerStartEndShape",
    "cornerStartStartShape",
    "cornerTopLeftShape",
    "cornerTopRightShape",
    "cornerTopShape",
    "counterIncrement",
    "counterReset",
    "counterSet",
    "cursor",
    "cx",
    "cy",
    "d",
    "descentOverride",
    "direction",
    "display",
    "dominantBaseline",
    "dynamicRangeLimit",
    "emptyCells",
    "epubCaptionSide",
    "epubTextCombine",
    "epubTextEmphasis",
    "epubTextEmphasisColor",
    "epubTextEmphasisStyle",
    "epubTextOrientation",
    "epubTextTransform",
    "epubWordBreak",
    "epubWritingMode",
    "fallback",
    "fieldSizing",
    "fill",
    "fillOpacity",
    "fillRule",
    "filter",
    "flex",
    "flexBasis",
    "flexDirection",
    "flexFlow",
    "flexGrow",
    "flexLineCount",
    "flexShrink",
    "flexWrap",
    "float",
    "floodColor",
    "floodOpacity",
    "font",
    "fontDisplay",
    "fontFamily",
    "fontFeatureSettings",
    "fontKerning",
    "fontLanguageOverride",
    "fontOpticalSizing",
    "fontPalette",
    "fontSize",
    "fontSizeAdjust",
    "fontStretch",
    "fontStyle",
    "fontSynthesis",
    "fontSynthesisSmallCaps",
    "fontSynthesisStyle",
    "fontSynthesisWeight",
    "fontVariant",
    "fontVariantAlternates",
    "fontVariantCaps",
    "fontVariantEastAsian",
    "fontVariantEmoji",
    "fontVariantLigatures",
    "fontVariantNumeric",
    "fontVariantPosition",
    "fontVariationSettings",
    "fontWeight",
    "forcedColorAdjust",
    "gap",
    "grid",
    "gridArea",
    "gridAutoColumns",
    "gridAutoFlow",
    "gridAutoRows",
    "gridColumn",
    "gridColumnEnd",
    "gridColumnGap",
    "gridColumnStart",
    "gridGap",
    "gridRow",
    "gridRowEnd",
    "gridRowGap",
    "gridRowStart",
    "gridTemplate",
    "gridTemplateAreas",
    "gridTemplateColumns",
    "gridTemplateRows",
    "height",
    "hyphenateCharacter",
    "hyphenateLimitChars",
    "hyphens",
    "imageOrientation",
    "imageRendering",
    "inherits",
    "initialLetter",
    "initialValue",
    "inlineSize",
    "inset",
    "insetBlock",
    "insetBlockEnd",
    "insetBlockStart",
    "insetInline",
    "insetInlineEnd",
    "insetInlineStart",
    "interactivity",
    "interestDelay",
    "interestDelayEnd",
    "interestDelayStart",
    "interpolateSize",
    "isolation",
    "justifyContent",
    "justifyItems",
    "justifySelf",
    "left",
    "letterSpacing",
    "lightingColor",
    "lineBreak",
    "lineGapOverride",
    "lineHeight",
    "listStyle",
    "listStyleImage",
    "listStylePosition",
    "listStyleType",
    "margin",
    "marginBlock",
    "marginBlockEnd",
    "marginBlockStart",
    "marginBottom",
    "marginInline",
    "marginInlineEnd",
    "marginInlineStart",
    "marginLeft",
    "marginRight",
    "marginTop",
    "marker",
    "markerEnd",
    "markerMid",
    "markerStart",
    "mask",
    "maskClip",
    "maskComposite",
    "maskImage",
    "maskMode",
    "maskOrigin",
    "maskPosition",
    "maskRepeat",
    "maskSize",
    "maskType",
    "mathDepth",
    "mathShift",
    "mathStyle",
    "maxBlockSize",
    "maxHeight",
    "maxInlineSize",
    "maxWidth",
    "minBlockSize",
    "minHeight",
    "minInlineSize",
    "minWidth",
    "mixBlendMode",
    "navigation",
    "negative",
    "objectFit",
    "objectPosition",
    "objectViewBox",
    "offset",
    "offsetAnchor",
    "offsetDistance",
    "offsetPath",
    "offsetPosition",
    "offsetRotate",
    "opacity",
    "order",
    "orphans",
    "outline",
    "outlineColor",
    "outlineOffset",
    "outlineStyle",
    "outlineWidth",
    "overflow",
    "overflowAnchor",
    "overflowBlock",
    "overflowClipMargin",
    "overflowInline",
    "overflowWrap",
    "overflowX",
    "overflowY",
    "overlay",
    "overrideColors",
    "overscrollBehavior",
    "overscrollBehaviorBlock",
    "overscrollBehaviorInline",
    "overscrollBehaviorX",
    "overscrollBehaviorY",
    "pad",
    "padding",
    "paddingBlock",
    "paddingBlockEnd",
    "paddingBlockStart",
    "paddingBottom",
    "paddingInline",
    "paddingInlineEnd",
    "paddingInlineStart",
    "paddingLeft",
    "paddingRight",
    "paddingTop",
    "page",
    "pageBreakAfter",
    "pageBreakBefore",
    "pageBreakInside",
    "pageMarginSafety",
    "pageOrientation",
    "paintOrder",
    "perspective",
    "perspectiveOrigin",
    "placeContent",
    "placeItems",
    "placeSelf",
    "pointerEvents",
    "position",
    "positionAnchor",
    "positionArea",
    "positionTry",
    "positionTryFallbacks",
    "positionTryOrder",
    "positionVisibility",
    "prefix",
    "printColorAdjust",
    "quotes",
    "r",
    "range",
    "readingFlow",
    "readingOrder",
    "resize",
    "result",
    "right",
    "rotate",
    "rowGap",
    "rowRule",
    "rowRuleBreak",
    "rowRuleColor",
    "rowRuleInset",
    "rowRuleInsetCap",
    "rowRuleInsetCapEnd",
    "rowRuleInsetCapStart",
    "rowRuleInsetEnd",
    "rowRuleInsetJunction",
    "rowRuleInsetJunctionEnd",
    "rowRuleInsetJunctionStart",
    "rowRuleInsetStart",
    "rowRuleStyle",
    "rowRuleVisibilityItems",
    "rowRuleWidth",
    "rubyAlign",
    "rubyOverhang",
    "rubyPosition",
    "rule",
    "ruleBreak",
    "ruleColor",
    "ruleInset",
    "ruleInsetCap",
    "ruleInsetEnd",
    "ruleInsetJunction",
    "ruleInsetStart",
    "ruleOverlap",
    "ruleStyle",
    "ruleVisibilityItems",
    "ruleWidth",
    "rx",
    "ry",
    "scale",
    "scrollBehavior",
    "scrollInitialTarget",
    "scrollMargin",
    "scrollMarginBlock",
    "scrollMarginBlockEnd",
    "scrollMarginBlockStart",
    "scrollMarginBottom",
    "scrollMarginInline",
    "scrollMarginInlineEnd",
    "scrollMarginInlineStart",
    "scrollMarginLeft",
    "scrollMarginRight",
    "scrollMarginTop",
    "scrollMarkerGroup",
    "scrollPadding",
    "scrollPaddingBlock",
    "scrollPaddingBlockEnd",
    "scrollPaddingBlockStart",
    "scrollPaddingBottom",
    "scrollPaddingInline",
    "scrollPaddingInlineEnd",
    "scrollPaddingInlineStart",
    "scrollPaddingLeft",
    "scrollPaddingRight",
    "scrollPaddingTop",
    "scrollSnapAlign",
    "scrollSnapStop",
    "scrollSnapType",
    "scrollTargetGroup",
    "scrollTimeline",
    "scrollTimelineAxis",
    "scrollTimelineName",
    "scrollbarColor",
    "scrollbarGutter",
    "scrollbarWidth",
    "shapeImageThreshold",
    "shapeMargin",
    "shapeOutside",
    "shapeRendering",
    "size",
    "sizeAdjust",
    "speak",
    "speakAs",
    "src",
    "stopColor",
    "stopOpacity",
    "stroke",
    "strokeDasharray",
    "strokeDashoffset",
    "strokeLinecap",
    "strokeLinejoin",
    "strokeMiterlimit",
    "strokeOpacity",
    "strokeWidth",
    "suffix",
    "symbols",
    "syntax",
    "system",
    "tabSize",
    "tableLayout",
    "textAlign",
    "textAlignLast",
    "textAnchor",
    "textAutospace",
    "textBox",
    "textBoxEdge",
    "textBoxTrim",
    "textCombineUpright",
    "textDecoration",
    "textDecorationColor",
    "textDecorationLine",
    "textDecorationSkipInk",
    "textDecorationStyle",
    "textDecorationThickness",
    "textEmphasis",
    "textEmphasisColor",
    "textEmphasisPosition",
    "textEmphasisStyle",
    "textFit",
    "textIndent",
    "textJustify",
    "textOrientation",
    "textOverflow",
    "textRendering",
    "textShadow",
    "textSizeAdjust",
    "textSpacingTrim",
    "textTransform",
    "textUnderlineOffset",
    "textUnderlinePosition",
    "textWrap",
    "textWrapMode",
    "textWrapStyle",
    "timelineScope",
    "timelineTrigger",
    "timelineTriggerActivationRange",
    "timelineTriggerActivationRangeEnd",
    "timelineTriggerActivationRangeStart",
    "timelineTriggerActiveRange",
    "timelineTriggerActiveRangeEnd",
    "timelineTriggerActiveRangeStart",
    "timelineTriggerName",
    "timelineTriggerSource",
    "top",
    "touchAction",
    "transform",
    "transformBox",
    "transformOrigin",
    "transformStyle",
    "transition",
    "transitionBehavior",
    "transitionDelay",
    "transitionDuration",
    "transitionProperty",
    "transitionTimingFunction",
    "translate",
    "triggerScope",
    "types",
    "unicodeBidi",
    "unicodeRange",
    "userSelect",
    "vectorEffect",
    "verticalAlign",
    "viewTimeline",
    "viewTimelineAxis",
    "viewTimelineInset",
    "viewTimelineName",
    "viewTransitionClass",
    "viewTransitionGroup",
    "viewTransitionName",
    "viewTransitionScope",
    "visibility",
    "webkitAlignContent",
    "webkitAlignItems",
    "webkitAlignSelf",
    "webkitAnimation",
    "webkitAnimationDelay",
    "webkitAnimationDirection",
    "webkitAnimationDuration",
    "webkitAnimationFillMode",
    "webkitAnimationIterationCount",
    "webkitAnimationName",
    "webkitAnimationPlayState",
    "webkitAnimationTimingFunction",
    "webkitAppRegion",
    "webkitAppearance",
    "webkitBackfaceVisibility",
    "webkitBackgroundClip",
    "webkitBackgroundOrigin",
    "webkitBackgroundSize",
    "webkitBorderAfter",
    "webkitBorderAfterColor",
    "webkitBorderAfterStyle",
    "webkitBorderAfterWidth",
    "webkitBorderBefore",
    "webkitBorderBeforeColor",
    "webkitBorderBeforeStyle",
    "webkitBorderBeforeWidth",
    "webkitBorderBottomLeftRadius",
    "webkitBorderBottomRightRadius",
    "webkitBorderEnd",
    "webkitBorderEndColor",
    "webkitBorderEndStyle",
    "webkitBorderEndWidth",
    "webkitBorderHorizontalSpacing",
    "webkitBorderImage",
    "webkitBorderRadius",
    "webkitBorderStart",
    "webkitBorderStartColor",
    "webkitBorderStartStyle",
    "webkitBorderStartWidth",
    "webkitBorderTopLeftRadius",
    "webkitBorderTopRightRadius",
    "webkitBorderVerticalSpacing",
    "webkitBoxAlign",
    "webkitBoxDecorationBreak",
    "webkitBoxDirection",
    "webkitBoxFlex",
    "webkitBoxOrdinalGroup",
    "webkitBoxOrient",
    "webkitBoxPack",
    "webkitBoxReflect",
    "webkitBoxShadow",
    "webkitBoxSizing",
    "webkitClipPath",
    "webkitColumnBreakAfter",
    "webkitColumnBreakBefore",
    "webkitColumnBreakInside",
    "webkitColumnCount",
    "webkitColumnGap",
    "webkitColumnRule",
    "webkitColumnRuleColor",
    "webkitColumnRuleStyle",
    "webkitColumnRuleWidth",
    "webkitColumnSpan",
    "webkitColumnWidth",
    "webkitColumns",
    "webkitFilter",
    "webkitFlex",
    "webkitFlexBasis",
    "webkitFlexDirection",
    "webkitFlexFlow",
    "webkitFlexGrow",
    "webkitFlexShrink",
    "webkitFlexWrap",
    "webkitFontFeatureSettings",
    "webkitFontSmoothing",
    "webkitHyphenateCharacter",
    "webkitJustifyContent",
    "webkitLineBreak",
    "webkitLineClamp",
    "webkitLocale",
    "webkitLogicalHeight",
    "webkitLogicalWidth",
    "webkitMarginAfter",
    "webkitMarginBefore",
    "webkitMarginEnd",
    "webkitMarginStart",
    "webkitMask",
    "webkitMaskBoxImage",
    "webkitMaskBoxImageOutset",
    "webkitMaskBoxImageRepeat",
    "webkitMaskBoxImageSlice",
    "webkitMaskBoxImageSource",
    "webkitMaskBoxImageWidth",
    "webkitMaskClip",
    "webkitMaskComposite",
    "webkitMaskImage",
    "webkitMaskOrigin",
    "webkitMaskPosition",
    "webkitMaskPositionX",
    "webkitMaskPositionY",
    "webkitMaskRepeat",
    "webkitMaskSize",
    "webkitMaxLogicalHeight",
    "webkitMaxLogicalWidth",
    "webkitMinLogicalHeight",
    "webkitMinLogicalWidth",
    "webkitOpacity",
    "webkitOrder",
    "webkitPaddingAfter",
    "webkitPaddingBefore",
    "webkitPaddingEnd",
    "webkitPaddingStart",
    "webkitPerspective",
    "webkitPerspectiveOrigin",
    "webkitPerspectiveOriginX",
    "webkitPerspectiveOriginY",
    "webkitPrintColorAdjust",
    "webkitRtlOrdering",
    "webkitRubyPosition",
    "webkitShapeImageThreshold",
    "webkitShapeMargin",
    "webkitShapeOutside",
    "webkitTapHighlightColor",
    "webkitTextCombine",
    "webkitTextDecorationsInEffect",
    "webkitTextEmphasis",
    "webkitTextEmphasisColor",
    "webkitTextEmphasisPosition",
    "webkitTextEmphasisStyle",
    "webkitTextFillColor",
    "webkitTextOrientation",
    "webkitTextSecurity",
    "webkitTextSizeAdjust",
    "webkitTextStroke",
    "webkitTextStrokeColor",
    "webkitTextStrokeWidth",
    "webkitTransform",
    "webkitTransformOrigin",
    "webkitTransformOriginX",
    "webkitTransformOriginY",
    "webkitTransformOriginZ",
    "webkitTransformStyle",
    "webkitTransition",
    "webkitTransitionDelay",
    "webkitTransitionDuration",
    "webkitTransitionProperty",
    "webkitTransitionTimingFunction",
    "webkitUserDrag",
    "webkitUserModify",
    "webkitUserSelect",
    "webkitWritingMode",
    "whiteSpace",
    "whiteSpaceCollapse",
    "widows",
    "width",
    "willChange",
    "wordBreak",
    "wordSpacing",
    "wordWrap",
    "writingMode",
    "x",
    "y",
    "zIndex",
    "zoom",
};

fn isSupportedPropertyName(name: []const u8) bool {
    for (supported_property_names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn queryNamed(self: *const CSSStyleProperties, name: []const u8) bool {
    if (isSupportedPropertyName(name)) return true;
    const index = std.fmt.parseUnsigned(u32, name, 10) catch return false;
    return index < self._proto.length();
}

fn getNames(self: *const CSSStyleProperties, frame: *Frame) !js.Array {
    const property_count = self._proto.length();
    var names = frame.js.local.?.newArray(@intCast(property_count + supported_property_names.len));

    for (0..property_count) |index| {
        const name = try std.fmt.allocPrint(frame.local_arena, "{d}", .{index});
        _ = try names.set(@intCast(index), name, .{});
    }
    for (supported_property_names, property_count..) |name, index| {
        _ = try names.set(@intCast(index), name, .{});
    }
    return names;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleProperties);

    pub const Meta = struct {
        // CSSStyleProperties is the Web IDL concrete type, but Chromium 151
        // still exposes element.style as CSSStyleDeclaration.
        pub const name = "CSSStyleDeclaration";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"[]" = bridge.namedIndexed(CSSStyleProperties.getNamed, CSSStyleProperties.setNamed, null, getNames, queryNamed, .{});
    pub const cssText = bridge.accessor(CSSStyleProperties.getCssText, CSSStyleProperties.setCssText, .{});
    pub const length = bridge.accessor(CSSStyleProperties.getLength, null, .{});
    pub const parentRule = bridge.accessor(CSSStyleProperties.getParentRule, null, .{});
    pub const cssFloat = bridge.accessor(CSSStyleProperties.getFloat, CSSStyleProperties.setFloat, .{});
    pub const getPropertyPriority = bridge.function(CSSStyleProperties.getPropertyPriority, .{});
    pub const getPropertyValue = bridge.function(CSSStyleProperties.getPropertyValue, .{});
    pub const item = bridge.function(CSSStyleProperties.item, .{});
    pub const removeProperty = bridge.function(CSSStyleProperties.removeProperty, .{});
    pub const setProperty = bridge.function(CSSStyleProperties.setProperty, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CSSStyleProperties" {
    try testing.htmlRunner("element/css_style_properties.html", .{});
}
