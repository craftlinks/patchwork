//! The code editor: one widget over a bounded buffer, drawn on the monospace grid.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Module Map
//! ```text
//! editor/language.zig  the language contract (State, Class, palette, next) and its check
//! editor/buffer.zig     the text (64 KiB, contiguous), line index, start states, undo
//! editor/tokenizer.zig  the patch language, the default: per-line states, seven classes
//! editor/editor.zig     the widget: geometry, drawing, keys, pointer, scrolling, rows
//! ```
//! The editor draws through `text/mono.zig` (one column per codepoint, the same glyph
//! instances as `text.place`), scrolls vertically in a step 14 view and horizontally on its
//! own, and edits only through `Buffer.replace`.
//!
//! ## 2. Data Flow
//! ```text
//! edit:  key / text / paste -> Buffer.replace -> line index shift -> start states from the
//!        edited line until one matches -> undo entry (merged or new) -> revision += 1
//! draw:  scroll -> visible lines (at most lines_max) -> per line: gutter number, faces and
//!        under-decorations, tokens from the cached start state -> glyphs; then strikes and
//!        the caret on layer 1; inline rows reserve height and are handed to the app
//! query: rect_of(byte) -> the character's logical rect, for anchors
//! ```
//!
//! ## 3. TigerStyle Invariants
//! - All storage is inside `Editor` (about 300 KiB); the app keeps it in static memory.
//! - Per-frame work is bounded by the visible lines and columns, decorations, and rows.

const editor = @import("editor/editor.zig");

pub const buffer = @import("editor/buffer.zig");
pub const tokenizer = @import("editor/tokenizer.zig");
pub const language = @import("editor/language.zig");

pub const EditorOf = editor.EditorOf;
pub const PaletteOf = editor.PaletteOf;
pub const StyleOf = editor.StyleOf;
pub const Token = language.Token;
pub const class_max = language.class_max;
pub const glyph_bound = editor.glyph_bound;
pub const lines_bound = editor.lines_bound;
pub const Editor = editor.Editor;
pub const Style = editor.Editor.Style;
pub const Palette = editor.Editor.Palette;
pub const Decoration = editor.Decoration;
pub const InlineRow = editor.InlineRow;
pub const RowSlot = editor.RowSlot;
pub const Action = editor.Action;
pub const Source = editor.Source;
pub const default_style = editor.Editor.default_style;
pub const default_palette = editor.Editor.default_palette;
pub const light_style = editor.Editor.light_style;
pub const light_palette = editor.Editor.light_palette;
pub const flags = editor.flags;
pub const decoration_cap = editor.decoration_cap;
pub const row_cap = editor.row_cap;
pub const row_height_max = editor.row_height_max;
pub const lines_max = editor.lines_max;
pub const columns_max = editor.columns_max;
pub const glyph_max = editor.glyph_max;
pub const padding_px = editor.padding_px;
pub const over_layer = editor.over_layer;

test {
    _ = buffer;
    _ = tokenizer;
    _ = language;
    _ = editor;
}
