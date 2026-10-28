//! The gallery's code page (step 44): the code editor in two languages beside each other, C
//! and XML, each from a recipe tokenizer.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Shows
//! A horizontal `widgets.Splitter` (ratio 0.5, panes at least 240 px) holds two editors:
//! `EditorOf(c)` on `sample.c` and `EditorOf(xml)` on `layout.xml`, each under a caption
//! naming its file and recipe. `c.zig` and `xml.zig` are recipes: languages an app copies
//! (the contract is `src/editor/language.zig`), not library code. The editors follow the
//! scheme: `restyle` sets each one's `default_palette` on a dark scheme and its
//! `light_palette` (the recipe's `palette_light` over the light chrome) on a light one.
//!
//! ## 2. Layout (logical pixels, from the page's top-left)
//! ```text
//! split   fill x fill   the C pane | the divider (6) | the XML pane
//! pane    fill x fill   caption (20, its words inset 8), 8 apart, then the editor (fill x
//!                       fill): the C editor at (16, 132), the XML editor at (643, 132),
//!                       each 621 x 556 at the ratio 0.5
//! ```
//!
//! ## 3. Budgets
//! Each editor's viewport is at most `pane_w_max` by `editor_h_max`, so a frame of this page
//! appends at most `glyph_max` glyphs (`editor.glyph_bound`, both editors and the captions)
//! and `box_max` boxes; the app adds them to its pools.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const input = patchwork.input;
const text = patchwork.text;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;
const editor = patchwork.editor;
const c = @import("c.zig");
const xml = @import("xml.zig");

pub const CEditor = editor.EditorOf(c);
pub const XmlEditor = editor.EditorOf(xml);

pub const split_id = ui.id("code_split", 0);
pub const c_id = ui.id("code_c", 0);
pub const xml_id = ui.id("code_xml", 0);

pub const sample_c = @embedFile("sample.c");
pub const layout_xml = @embedFile("layout.xml");

pub const c_caption = "sample.c (c.zig, a recipe)";
pub const xml_caption = "layout.xml (xml.zig, a recipe)";

const split_ratio: f32 = 0.5;
pub const pane_min: f32 = 240;
pub const gap_px: f32 = 8;
pub const caption_px: f32 = 20;
/// The captions' inset, so the XML pane's clears the divider.
const caption_inset: f32 = 8;

/// The page is 1248 x 584 (the gallery's page); a pane is at most the page less the other
/// pane's minimum and the divider, and an editor the pane's height less its caption.
pub const page_w: f32 = 1248;
pub const page_h: f32 = 584;
pub const pane_w_max: f32 = page_w - pane_min - widgets.splitter_px;
pub const editor_h_max: f32 = page_h - caption_px - gap_px;

/// Glyphs one frame of the page appends at most: both editors at their largest viewports,
/// and the captions.
pub const glyph_max: u32 = 2 * editor.glyph_bound(pane_w_max, editor_h_max, text_size) +
    c_caption.len + xml_caption.len;
/// Boxes one frame of the page appends at most: per editor its background, gutter, a band
/// per drawn line (the current line or the selection), the caret, and its view's thumb.
pub const box_max: u32 = 2 * (4 + editor.lines_bound(editor_h_max, text_size));
/// Areas: per editor its own, its view, and its thumb; the divider.
pub const area_max: u32 = 2 * 3 + 1;

const text_size: f32 = CEditor.default_style.size;

/// What an editor did, for the status line.
pub const Report = struct {
    language: []const u8,
    action: editor.Action,
};

pub const Page = struct {
    split: widgets.Splitter,
    c_editor: CEditor,
    xml_editor: XmlEditor,

    /// Both samples loaded, the caret at their starts. In place: the editors are about 300
    /// KiB each.
    pub fn init(self: *Page) void {
        self.split = widgets.Splitter.init(split_id, .horizontal, split_ratio, pane_min, pane_min);
        self.c_editor.init(c_id, CEditor.default_style);
        self.xml_editor.init(xml_id, XmlEditor.default_style);
        const c_loaded = self.c_editor.load(sample_c);
        const xml_loaded = self.xml_editor.load(layout_xml);
        assert(c_loaded and xml_loaded);
    }

    /// Sets both editors' palettes for `scheme`: the light ones when its background is light.
    pub fn restyle(self: *Page, scheme: *const patchwork.theme.Scheme) void {
        const light = luminance(scheme.colors.background) > 0.5;
        self.c_editor.style.palette = if (light) CEditor.light_palette else CEditor.default_palette;
        self.xml_editor.style.palette = if (light) XmlEditor.light_palette else XmlEditor.default_palette;
        assert(self.c_editor.style.size == text_size);
        assert(self.xml_editor.style.size == text_size);
    }

    /// Routes `event` to both editors and reports the last edit; the app routes the divider.
    pub fn handle(self: *Page, cx: anytype, event: input.Event) ?Report {
        var report: ?Report = null;
        const c_action = self.c_editor.handle(cx, event);
        if (c_action != .none) report = .{ .language = "c", .action = c_action };
        const xml_action = self.xml_editor.handle(cx, event);
        if (xml_action != .none) report = .{ .language = "xml", .action = xml_action };
        return report;
    }

    pub fn draw(self: *Page, cx: anytype) void {
        _ = self.split.begin(cx, ui.sized(.fill, .fill));
        pane(cx, c_caption);
        self.c_editor.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        _ = self.split.next(cx);
        pane(cx, xml_caption);
        self.xml_editor.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        self.split.end(cx);
    }
};

/// Opens a pane's column and draws its caption; the caller draws the editor and closes it.
fn pane(cx: anytype, words: []const u8) void {
    _ = cx.begin(ui.sized(.fill, .fill), .{ .flow = .down, .spacing = gap_px });
    const line = cx.walk(ui.sized(.fill, .{ .fixed = caption_px }));
    const clip = cx.visible(line) orelse return;
    const style: text.Style = .{ .face = .sans, .size = 14, .color = cx.theme().colors.text };
    kit.label(cx, style, words, ui.cx.inset(line, .xy(caption_inset, 0)), clip, start);
}

/// Rec. 709 luminance of a straight RGBA colour, ignoring alpha.
fn luminance(color: [4]f32) f32 {
    assert(color[0] >= 0 and color[0] <= 1);
    return 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2];
}

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };

comptime {
    // 1,002 x 556 at 15 px: 28 lines of 114 columns and 4 digits per editor (6,608 for
    // both, not 2 * 26,112), and the captions' 56.
    assert(editor.glyph_bound(pane_w_max, editor_h_max, text_size) == 28 * (114 + 4));
    assert(glyph_max == 6_664);
    assert(box_max == 64);
    assert(pane_w_max > pane_min);
    assert(glyph_max < 2 * editor.glyph_max);
    assert(box_max <= 2 * (4 + editor.lines_max));
}

// Locks the samples against their recipes: every line of each passes the language
// contract, `sample.c` opens and closes block comments, and `layout.xml` reaches every XML
// state, so the page shows each construct crossing a line.
test "the samples meet their languages and reach every state" {
    const language = editor.language;
    var c_state: c.State = .normal;
    var c_seen: [2]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, sample_c, '\n');
    while (lines.next()) |line| {
        c_seen[@backingInt(c_state)] = true;
        c_state = language.verify_line(c, line, c_state);
    }
    try std.testing.expectEqual(c.State.normal, c_state);
    try std.testing.expect(c_seen[0] and c_seen[1]);
    var xml_state: xml.State = .normal;
    var xml_seen: [8]bool = @splat(false);
    lines = std.mem.splitScalar(u8, layout_xml, '\n');
    while (lines.next()) |line| {
        xml_seen[@backingInt(xml_state)] = true;
        xml_state = language.verify_line(xml, line, xml_state);
    }
    try std.testing.expectEqual(xml.State.normal, xml_state);
    for (xml_seen) |seen| try std.testing.expect(seen);
}
