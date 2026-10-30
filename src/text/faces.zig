//! `FaceSet`: the monospace grid's frame protocol for a line set in several faces, where a
//! glyph's advance is its own.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Beside `Mono`
//! `text/mono.zig` can multiply: every ASCII glyph of its one face advances the same. A
//! proportional line is a sum of advances, so `FaceSet` keeps two tables per face, the cache
//! entries of the 94 inked ASCII glyphs and the advances of all 95 printable ones, and a pen
//! comes from whoever sums them (`editor/editor.zig`, section 2). There is no shaping, kerning,
//! ligature, or bidi: a line is a sum of advances, as `text.place` is.
//!
//! ## 2. Slots
//! `FaceSet(faces)` takes one face per token class. Classes that share a face share a slot, so
//! its tables exist once: `slots[class]` is the class's slot, and `slot_count` the distinct
//! faces. Slot 0 is `faces[0]`'s, which a gap between tokens is set in
//! (`editor/language.zig`, section 2).
//!
//! ## 3. Frame Protocol
//! ```text
//! prepare(cx, size)   once per draw: metrics, size key, scale, and each slot's tables
//!                     (94 cache lookups a slot; a miss rasterizes)
//! advance(slot, cp)   ASCII: a table load; others: the font's advance
//! emit(cx, slot, cp, pen, baseline_px, paint)
//!                     as `Mono.emit`, skipped entries and blank glyphs append nothing
//! ```
//! Three faces make 282 first-frame lookups against the cache's per-frame `budget` of 256. The
//! rest stay pending and the host draws again, as for any first frame.
//!
//! ## 4. Line Metrics (logical pixels)
//! ```text
//! ascent, descent  the maxima over the slots, so every face shares one baseline
//! line_height      ceil(ascent + descent)
//! baseline_px      round((top + (line_height - ascent - descent) / 2 + ascent) * scale)
//! ```
//! The rule of `text/mono.zig`, section 3, over those maxima. With one face it equals
//! `text.place`'s vertically centred baseline in a rect `line_height` tall, so a line in one
//! face writes the records `place` writes (test "a line in one face writes what text.place
//! writes").
//!
//! ## 5. TigerStyle Invariants
//! - Tables are fixed arrays sized by the slots; nothing allocates.
//! - `emit` and `advance` are O(1), with one cache probe at most.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const ttf = @import("ttf.zig");
const cache = @import("cache.zig");
const layout = @import("layout.zig");

pub const Paint = layout.Paint;

const first_ink: u8 = '!';
const last_ink: u8 = '~';

/// The per-frame tables of `faces`, one face per token class. See the module guide.
pub fn FaceSet(comptime faces: []const text.Face) type {
    comptime assert(faces.len >= 1);
    const Distinct = struct {
        slots: [faces.len]u8,
        count: u8,
        unique: [faces.len]text.Face,
    };
    const distinct: Distinct = comptime blk: {
        var slots: [faces.len]u8 = undefined;
        var unique: [faces.len]text.Face = undefined;
        var count: u8 = 0;
        for (faces, 0..) |face, class| {
            var slot: u8 = 0;
            while (slot < count and unique[slot] != face) slot += 1;
            if (slot == count) {
                unique[count] = face;
                count += 1;
            }
            slots[class] = slot;
        }
        break :blk .{ .slots = slots, .count = count, .unique = unique };
    };
    return struct {
        const Self = @This();

        /// The distinct faces.
        pub const slot_count: u32 = distinct.count;
        /// Each class's slot (section 2).
        pub const slots: [faces.len]u8 = distinct.slots;
        const face_of: [slot_count]text.Face = distinct.unique[0..slot_count].*;

        /// Cache entries of ASCII glyphs by byte; key 0 is skipped this frame or not drawn.
        tables: [slot_count][128]cache.Entry,
        /// Advances of printable ASCII glyphs by byte, in logical pixels.
        advances: [slot_count][128]f32,
        size: f32,
        size_q: u32,
        scale: f32,
        ascent: f32,
        descent: f32,
        line_height: f32,

        /// The tallest ascent of the faces at `size`.
        fn ascent_of(size: f32) f32 {
            var most: f32 = 0;
            for (face_of) |face| {
                const font = text.font_of(face);
                const em = size / @as(f32, @floatFromInt(font.units_per_em));
                most = @max(most, @as(f32, @floatFromInt(font.ascent)) * em);
            }
            return most;
        }

        /// The deepest descent of the faces at `size`.
        fn descent_of(size: f32) f32 {
            var most: f32 = 0;
            for (face_of) |face| {
                const font = text.font_of(face);
                const em = size / @as(f32, @floatFromInt(font.units_per_em));
                most = @max(most, @as(f32, @floatFromInt(font.descent)) * em);
            }
            return most;
        }

        /// The line pitch at `size` (section 4). Callable at compile time.
        pub fn line_height_of(size: f32) f32 {
            assert(size > 0);
            assert(size <= text.size_max);
            return @ceil(ascent_of(size) + descent_of(size));
        }

        /// Fills every slot for `size` at the draw context's scale and looks up the inked
        /// ASCII glyphs. Draw phase only; `cx` is the draw context.
        pub fn prepare(self: *Self, cx: anytype, size: f32) void {
            assert(size > 0);
            assert(cx.text.scale_120 >= 1);
            self.size = size;
            self.size_q = cx.text.size_key_of(size);
            self.scale = cx.text.device_scale();
            self.ascent = ascent_of(size);
            self.descent = descent_of(size);
            self.line_height = line_height_of(size);
            for (face_of, 0..) |face, slot| self.prepare_slot(cx, slot, face);
            assert(self.line_height >= self.ascent + self.descent);
        }

        fn prepare_slot(self: *Self, cx: anytype, slot: usize, face: text.Face) void {
            const font = text.font_of(face);
            const table = &self.tables[slot];
            for (table) |*entry| entry.key = 0;
            self.advances[slot] = @splat(0);
            var byte: u8 = ' ';
            while (byte <= last_ink) : (byte += 1) {
                const id = font.ascii[byte];
                self.advances[slot][byte] = logical(font, id, self.size);
                if (byte < first_ink) continue;
                const glyph = cx.text.glyph(@backingInt(face), font, id, self.size_q);
                if (glyph) |entry| table[byte] = entry;
            }
            assert(table[' '].key == 0);
        }

        /// The advance of `codepoint` in `slot`, in logical pixels. Requires `prepare`.
        pub fn advance(self: *const Self, slot: u8, codepoint: u21) f32 {
            assert(slot < slot_count);
            assert(self.size > 0);
            if (codepoint < 128) return self.advances[slot][codepoint];
            const font = text.font_of(face_of[slot]);
            return logical(font, ttf.glyph_id(font, codepoint), self.size);
        }

        /// The device row of the baseline of a line whose top is `top` (section 4).
        pub fn baseline_of(self: *const Self, top: f32) f32 {
            assert(self.scale > 0);
            assert(top == top);
            const gap = self.line_height - self.ascent - self.descent;
            return @round((top + gap * 0.5 + self.ascent) * self.scale);
        }

        /// Appends the glyph of `codepoint` in `slot` with its pen at `pen_x` on `baseline_px`.
        /// Nothing for a glyph without ink, a control, or one the cache skipped this frame.
        pub fn emit(
            self: *const Self,
            cx: anytype,
            slot: u8,
            codepoint: u21,
            pen_x: f32,
            baseline_px: f32,
            paint: Paint,
        ) void {
            assert(slot < slot_count);
            assert(paint.clip.x1 > paint.clip.x0);
            const entry = if (codepoint < 128)
                self.tables[slot][codepoint]
            else
                self.lookup(cx, slot, codepoint);
            if (entry.key == 0) return;
            if (entry.width == 0) return;
            const scale = self.scale;
            const glyph = layout.instance_of(entry, self.size_q, pen_x, baseline_px, scale, paint);
            layout.append_glyph(cx, glyph);
        }

        fn lookup(self: *const Self, cx: anytype, slot: u8, codepoint: u21) cache.Entry {
            assert(codepoint >= 128);
            const face = face_of[slot];
            const font = text.font_of(face);
            const id = ttf.glyph_id(font, codepoint);
            const none: cache.Entry = .{
                .key = 0,
                .x = 0,
                .y = 0,
                .left = 0,
                .top = 0,
                .raster_q = 1,
                .width = 0,
                .height = 0,
            };
            return cx.text.glyph(@backingInt(face), font, id, self.size_q) orelse none;
        }
    };
}

fn logical(font: *const ttf.Font, id: u16, size: f32) f32 {
    return layout.units_to_logical(ttf.advance(font, id), size, font.units_per_em);
}

const testing = std.testing;
const types = @import("../draw/types.zig");
const draw = @import("../draw.zig");
const registry = @import("../draw/registry.zig");

const test_draw = [_]registry.DrawType{
    .{ .type = types.Glyph, .cap = 256 },
};

const TestContext = draw.Context(&test_draw, 4, 0);

fn test_context(scale_120: u32) *TestContext {
    const static = struct {
        var context: TestContext = undefined;
    };
    static.context.init();
    static.context.text.scale_120 = scale_120;
    static.context.reset();
    return &static.context;
}

const Set = FaceSet(&.{ .sans, .sans_bold, .sans, .mono });

// Locks the slots of section 2: four classes of three faces are three slots, slot 0 being
// `faces[0]`'s, and the classes that share a face share its slot.
test "classes that share a face share a slot" {
    try testing.expectEqual(@as(u32, 3), Set.slot_count);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2 }, &Set.slots);
}

// Locks the metrics of section 4: the pitch is the maxima's, not any one face's, and advances
// are each face's own, `i` narrower than the mono face's 600 units, ASCII and not.
test "advances are each face's and the line takes the maxima" {
    const cx = test_context(120);
    var set: Set = undefined;
    set.prepare(cx, 15);
    var most: f32 = 0;
    for ([_]text.Face{ .sans, .sans_bold, .mono }) |face| {
        const font = text.font_of(face);
        most = @max(most, @as(f32, @floatFromInt(font.ascent + font.descent)) * 15 / 1000);
    }
    try testing.expect(set.line_height >= most);
    try testing.expectEqual(set.line_height, comptime Set.line_height_of(15));
    try testing.expect(set.advance(0, 'i') < set.advance(2, 'i'));
    try testing.expectEqual(@as(f32, 9), set.advance(2, 'i'));
    try testing.expect(set.advance(1, ' ') > 0);
    const style: text.Style = .{ .face = .sans, .size = 15, .color = @splat(1) };
    try testing.expectEqual(text.measure(style, "\u{e4}"), set.advance(0, 0xE4));
}

// Locks byte-for-byte agreement with `text.place`: a line of one face emitted glyph by glyph,
// its pen a running sum of `advance`, writes exactly the records `place` writes for the same
// bytes in a rect one line tall, non-ASCII included, at scales 1, 1.5, and 2, once both caches
// packed their glyphs in the same order.
test "a line in one face writes what text.place writes" {
    const One = FaceSet(&.{.sans});
    const line = "k(-0.98~0.445, \"fl\u{e4}nge\") // Wi";
    const clip: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };
    const color: [4]f32 = .{ 0.5, 0.75, 1, 1 };
    for ([_]u32{ 120, 180, 240 }) |scale_120| {
        const height = One.line_height_of(15);
        const rect: draw.Rect = .{ .x = 10.25, .y = 31.5, .width = 900, .height = height };
        const placed = test_context(scale_120);
        var warm: One = undefined;
        warm.prepare(placed, 15);
        const style: text.Style = .{ .face = .sans, .size = 15, .color = color };
        const options: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
        text.place(placed, style, line, rect, clip, options);
        var expected: [64]types.Glyph = undefined;
        const count = placed.items(types.Glyph).len;
        @memcpy(expected[0..count], placed.items(types.Glyph));
        const set_cx = test_context(scale_120);
        var set: One = undefined;
        set.prepare(set_cx, 15);
        const baseline = set.baseline_of(rect.y);
        var pen = rect.x;
        var index: u32 = 0;
        while (index < line.len) {
            const codepoint = layout.decode(line, &index);
            set.emit(set_cx, 0, codepoint, pen, baseline, .{ .clip = clip, .color = color });
            pen += set.advance(0, codepoint);
        }
        try testing.expectEqual(count, set_cx.items(types.Glyph).len);
        try testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(expected[0..count]),
            std.mem.sliceAsBytes(set_cx.items(types.Glyph)),
        );
    }
}

// Locks the budget of section 3: two faces are 188 lookups, all inside one frame, and three
// are 282, of which 26 stay pending for the next draw, which leaves none.
test "prepare warms each face and leaves the rest pending" {
    const cx = test_context(120);
    var two: FaceSet(&.{ .sans, .sans_bold }) = undefined;
    two.prepare(cx, 15);
    try testing.expectEqual(@as(u32, 188), cx.text.new_count);
    try testing.expectEqual(@as(u32, 0), cx.text.pending);
    const again = test_context(120);
    var three: Set = undefined;
    three.prepare(again, 15);
    try testing.expectEqual(@as(u32, 26), again.text.pending);
    again.reset();
    three.prepare(again, 15);
    try testing.expectEqual(@as(u32, 0), again.text.pending);
}
