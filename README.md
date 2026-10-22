# Patchwork

A Zig 0.16.0 library copying Makepad's drawing model: a retained widget tree that
lays itself out with a turtle and paints with instanced signed-distance shaders.
Patchwork provides a compile-time application contract that compiles to both native
Linux (Wayland + wgpu-native) and the browser (`wasm32-freestanding` + WebGPU) from
a single Zig app definition without dynamic dispatch or vtables.

## The App Contract

An application defines a type satisfying the contract in `src/app.zig`:

```zig
pub const App = struct {
    pub const config: patchwork.app.Config = .{
        .title = "...",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = patchwork.draw.Box, .cap = 64 },
            .{ .type = patchwork.draw.Glyph, .cap = 256 },
        },
    };
    pub fn init(app: *App, textures: *patchwork.draw.Textures) void
    pub fn layout(app: *App, width_logical: u32, height_logical: u32) void
    pub fn event(app: *App, event: patchwork.input.Event) bool      // true: dirty
    pub fn timer(app: *App, now_ms: u64) bool                      // true: dirty
    pub fn live(app: *const App) bool
    pub fn dirty(app: *const App) bool
    pub fn draw(app: *App, cx: *patchwork.app.Context(App)) void
};
```

### Contract Declarations

| Declaration | Signature | Description |
|---|---|---|
| `config` | `Config` | `title`, `timer_period_ms`, `draw` (types and capacities), `batch_cap`. |
| `init` | `fn (*App, *draw.Textures) void` | Called once before any other call; may create textures. |
| `layout` | `fn (*App, u32, u32) void` | Positions widgets for logical `(w, h)` on size change. |
| `event` | `fn (*App, Event) bool` | Applies pointer/frame events; returns true if dirty. |
| `timer` | `fn (*App, u64) bool` | Called on host timer expiration; returns true if dirty. |
| `live` | `fn (*const App) bool` | True while an animator is moving; gates frame callbacks. |
| `dirty` | `fn (*const App) bool` | True when `draw` is owed; cleared by `draw`. |
| `draw` | `fn (*App, *app.Context(App)) void` | Appends every instance to the reset draw context. |

The contract is validated at compile time by `patchwork.app.check(App)`. Missing or
mistyped declarations, a draw type that breaks the instance convention (the message names
the type), a zero capacity, and a `batch_cap` whose worst frame would not fit one command
buffer produce a clear `@compileError` naming the exact problem.

Applications manage widget collections using `patchwork.ui.Scene(Widget, widget_cap)`,
a generic dispatcher that implements back-to-front hit testing, hover tracking, and
press capture over an app-defined tagged union of widgets without dynamic memory allocation.

## Repository Layout

```text
patchwork/
├── src/                        # Core library module ("patchwork")
│   ├── root.zig                # Library entry point; re-exports modules and host
│   ├── app.zig                 # App contract definitions and comptime check
│   ├── ui.zig                  # Generic Scene(Widget, widget_cap) dispatcher
│   ├── widgets.zig             # Retained widgets (Panel, Button, Slider, Knob, Meter, Toggle, Scroll)
│   ├── draw.zig                # Drawing namespace: projection, unit quad, dirty ranges, re-exports
│   ├── draw/registry.zig       # DrawType, instance convention check, WGSL assembly, layouts
│   ├── draw/prelude.wgsl       # Shared vs_main, fs_main, coverage, clip mask, distance fields
│   ├── draw/types.zig          # Library draw types (Box, Arc, Glyph, Image) and CPU twins
│   ├── draw/pools.zig          # Context: per-type pools, layers, counting sort, sticky batches
│   ├── draw/textures.zig       # Textures: queued creates and writes, TextureId
│   ├── draw/renderer.zig       # Records setup and frame command streams (pipelines, uploads, draws)
│   ├── turtle.zig              # 2D turtle layout engine (place_column, place_row, Walk, Size)
│   ├── text.zig                # Text namespace: faces, Style, measure, place, place_runs
│   ├── text/ttf.zig            # Comptime TrueType reader: cmap 12/4, hmtx, glyf, composites
│   ├── text/raster.zig         # Quadratic flattening and exact signed-area coverage
│   ├── text/cache.zig          # Glyph cache: hash table, shelf-packed atlas, CPU mirror, budget
│   ├── text/layout.zig         # UTF-8, alignment, ellipsis, device-pixel snapping
│   ├── text/fonts/             # Noto Sans Regular and Bold, Noto Sans Mono (SIL OFL, OFL.txt)
│   ├── animator.zig            # Scalar animator transitions (Animator, Clock)
│   ├── frame.zig               # Presentation and damage policy (Frame)
│   ├── input.zig               # Pointer events and bounded EventQueue
│   ├── theme.zig               # Theme uniform record packed behind the projection matrix
│   ├── gpu.zig                 # Cross-platform GPU seam: create and submit
│   ├── gpu/commands.zig        # GPU command stream: op encoding, decoder, generated op table
│   └── serve.zig               # Built-in static HTTP server for browser testing
├── src/host/                   # Platform host implementations generic over App
│   ├── native_main.zig         # Native executable entry point: runs linux_window.run(app.App)
│   ├── web_main.zig            # Wasm entry point: calls web_exports.export_app(app.App)
│   ├── linux_window.zig        # Linux Wayland event loop, timerfd, and Host(App)
│   ├── web_exports.zig         # Wasm exports and zero-copy FFI bridge via @export
│   ├── gpu_wgpu.zig            # Native replayer: id tables, execute, swapchain
│   ├── wl_seat.zig             # Wayland seat and pointer listener
│   ├── wl_callback.zig         # Wayland frame completion callback
│   ├── wp_presentation.zig     # Wayland presentation-time feedback listener
│   ├── wp_fractional_scale.zig # wp_fractional_scale_v1 and wp_viewporter bindings
│   └── xdg_shell.zig           # XDG shell surface and toplevel protocol
├── examples/                   # Example applications
│   ├── rack/                   # Modular synthesizer rack
│   │   ├── app.zig             # Rack App implementing the patchwork.app contract
│   │   ├── levels.zig          # Procedural triangle-wave meter sampling
│   │   ├── led.zig             # The rack's own draw type: a glowing LED
│   │   └── badge.zig           # Procedural 32 by 32 RGBA badge texture
│   └── column/                 # Scroll column regression app
│       └── app.zig             # Column App (config.timer_period_ms = 0)
├── web/                        # Browser harness
│   ├── index.html              # WebGPU canvas host page
│   └── shell.js                # Generic command interpreter, Wasm bridge, and input handler
└── test/                       # Regression tests
    ├── contract_missing_draw.zig # Test verifying that missing draw fails compilation
    └── contract_ragged_type.zig  # Test verifying that a 36-byte draw type fails compilation
```

## Build Steps

Use the distro `zig` (`/usr/bin/zig` on this machine; Zig 0.16.0).

```bash
# Examples (Rack)
zig build run             # Build and run the synthesizer rack natively (Wayland + wgpu-native)
zig build wasm            # Compile the rack to zig-out/bin/rack.wasm (wasm32-freestanding)
zig build serve           # Serve the rack WebGPU application on localhost (prints the address)

# Examples (Scroll Column)
zig build run-column      # Build and run the scroll column natively
zig build wasm-column     # Compile the scroll column to zig-out/bin/column.wasm
zig build serve-column    # Serve the scroll column WebGPU application on localhost (prints the address)

# Validation
zig build test            # Run unit tests across the library and both examples
zig build test-contract   # Verify compile errors for a missing `draw` and a ragged draw type
```

An optional override flag `-Dwgpu-lib-dir=` is available if you wish to link against a
custom unpack directory or local build of `wgpu-native`:

```bash
zig build run -Dwgpu-lib-dir=/path/to/wgpu-native/lib
```

## Use Patchwork From Another Project

A consumer project defines its application in a single file declaring `pub const App`
satisfying `patchwork.app.Config`. Patchwork builds the application natively, as WebAssembly,
serves it on localhost, and runs its tests from that one app file.

Note that `Config.title` is `[:0]const u8` and the `AppSteps` struct field for running
tests is `tests`.

### 1. `build.zig.zon`

Add Patchwork as a dependency:

```zig
.{
    .name = .synth,
    .version = "0.0.0",
    .fingerprint = 0x141efc6c2804bd6a,
    .dependencies = .{
        .patchwork = .{ .path = "../patchwork" },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

### 2. `build.zig`

The consumer `build.zig` calls `patchwork.addApp` passing its own builder and
`dep.builder`:

```zig
const std = @import("std");
const patchwork = @import("patchwork");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("patchwork", .{ .target = target, .optimize = optimize });
    const steps = patchwork.addApp(b, dep.builder, .{
        .name = "synth",
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.step("run", "Run natively").dependOn(steps.run);
    b.step("wasm", "Build for the browser").dependOn(steps.wasm);
    b.step("serve", "Serve on localhost").dependOn(steps.serve);
    b.step("test", "Run app tests").dependOn(steps.tests);
    b.getInstallStep().dependOn(steps.install);
}
```

### 3. `src/app.zig`

The consumer's app root satisfies the contract:

```zig
const std = @import("std");
const patchwork = @import("patchwork");
const widgets = patchwork.widgets;
const turtle = patchwork.turtle;
const animator = patchwork.animator;
const theme = patchwork.theme;
const quads = patchwork.draw;

const Widget = union(enum) { panel: widgets.Panel, knob: widgets.Knob };
const Scene = patchwork.ui.Scene(Widget, 2);
const none: turtle.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

pub const App = struct {
    scene: Scene,

    pub const config: patchwork.app.Config = .{
        .title = "synth",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 8 },
            .{ .type = quads.Arc, .cap = 8 },
            .{ .type = quads.Glyph, .cap = 64 },
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.scene = Scene.init(2);
        const c = theme.chrome.panel;
        app.scene.widgets[0] = .{ .panel = .{
            .id = 1,
            .rect = none,
            .padding = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 },
            .walk = .{ .margin = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, .width = .fill, .height = .fill, .align_x = 0 },
            .label = .{
                .text = "synth",
                .rect = none,
                .style = .{ .face = .sans_bold, .size = 14, .color = .{ 1, 1, 1, 1 } },
            },
            .paint = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3], .radius = 8 },
            .hover = animator.Animator.init(widgets.hover_rate_per_ms),
            .down = animator.Animator.init(widgets.down_rate_per_ms),
        } };
        var knob: widgets.Knob = .{
            .id = 2,
            .rect = none,
            .name = "gain",
            .value_text = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .walk = .{ .margin = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, .width = .{ .fixed = 144 }, .height = .{ .fixed = 72 }, .align_x = 0 },
            .value = 0.5,
            .accent = widgets.accents[0],
            .hover = animator.Animator.init(widgets.hover_rate_per_ms),
            .drag_y = 0,
        };
        knob.set_value(0.5);
        app.scene.widgets[1] = .{ .knob = knob };
    }

    pub fn layout(app: *App, w: u32, h: u32) void {
        const panel = &app.scene.widgets[0].panel;
        panel.rect = .{ .x = 16, .y = 16, .width = @floatFromInt(w - 32), .height = @floatFromInt(h - 32) };
        widgets.place_label(&panel.label, panel.rect, panel.padding);
        app.scene.widgets[1].knob.rect = .{ .x = 32, .y = 56, .width = 144, .height = 72 };
        app.scene.finish_layout(w, h);
    }

    pub fn event(app: *App, e: patchwork.input.Event) bool {
        return app.scene.handle_event(e);
    }
    pub fn timer(app: *App, now_ms: u64) bool {
        _ = app;
        _ = now_ms;
        return false;
    }
    pub fn live(app: *const App) bool {
        return app.scene.live();
    }
    pub fn dirty(app: *const App) bool {
        return app.scene.dirty;
    }

    pub fn draw(app: *App, cx: *patchwork.app.Context(App)) void {
        const w: f32 = @floatFromInt(app.scene.width_logical);
        const h: f32 = @floatFromInt(app.scene.height_logical);
        const clip: patchwork.draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        app.scene.widgets[0].panel.draw(cx, clip);
        app.scene.widgets[1].knob.draw(cx, clip);
        app.scene.finish_draw();
    }
};

// Static, like the hosts' context, so the pools stay off the stack.
var context: patchwork.app.Context(App) = undefined;

test "layout then draw is clean" {
    context.init();
    var app: App = undefined;
    App.init(&app, &context.textures);
    app.layout(400, 300);
    try std.testing.expect(app.dirty());
    context.reset();
    app.draw(&context);
    try std.testing.expect(!app.dirty());
    try std.testing.expectEqual(@as(u32, 0), context.overflow_count);
    try std.testing.expect(context.items(quads.Arc).len >= 1);
}
```

## Turtle Layout Architecture

Flow is downward in columns and left-to-right in rows (`turtle.place_column` and
`turtle.place_row`). Sizing is `fixed`, `fill`, or `fit`. Padding lives on the
container, while `margin`, `width`, `height`, and `align_x` live on each child's `Walk`.
Container padding insets the inner rectangle where children walk. The turtle advances a
cursor along the main axis and writes border-box instance rectangles (margins excluded).
Children with `fill` height in a column share leftover main-axis space equally. In a row,
`place_row` is the horizontal transpose: width `fill` shares leftover width, while height
`fill` takes the row height minus that child's vertical margins (it does not split height
among siblings). `align_x` is checked and does not move a row child; rows have no cross-axis
alignment. Oversized fixed dimensions are not clamped. If a child resolves to a non-positive
edge, it is still placed and still advances the cursor so siblings keep their positions, but
widgets skip it and `draw.Context.append` rejects it to protect the GPU from degenerate quads.

Layout executes in two bounded passes with zero heap allocation, bounded by `turtle.child_cap`.
Window resize sets `Frame.relayout`, rebuilding the draw pools. A display scale change leaves
`Frame.relayout` false: the column is not re-walked. The hosts still redraw the scene once,
because glyphs are rasterized and snapped at the device scale, and only the glyph records
change (see Text below).

## Example Applications

Worked coordinates, initial values, palettes, and budgets live in the examples' tests, not
here, so they cannot drift. Run `zig build test` for the checked numbers.

### 1. Synthesizer Rack (`examples/rack/app.zig`)

A modular rack in a full-window column under a header bar: a stack of panels, each holding a
row of knobs and a level meter. It demonstrates:
- **Text.** The header shows a 32 px monospace "121.00" and a bold "BPM" sharing one baseline
  (`text.place_runs`) and the label "Jürgen Köhler · Café" (composite and non-ASCII glyphs),
  right-aligned and cut with an ellipsis when the bar is narrow. Panel titles are bold 14 px,
  and knob values are monospace (`widgets.value_style`).
- **Flat widget list.** One `Scene` array holds panels, knobs, and meters. Hit testing scans
  back to front and later slots win, so a knob or meter wins over its backing panel without
  nested containers. The slot and per-pool budgets are `comptime` asserts in `app.zig`.
- **Clipping.** Knob faces clip to the parent panel and meter faces clip to the meter cell,
  so a track cannot cover the title. A knob or meter whose box does not fit is omitted rather
  than drawn over its neighbor. Panel faces carry the window clip.
- **Per-instance accents.** Knob accents are per-instance colors (`draw.Arc.color`), not theme
  slots. The palette is `widgets.accents`.
- **An app-defined draw type** (`examples/rack/led.zig`). `Led` is an `extern struct` plus a
  WGSL `pixel` function, registered in `config.draw` with no library edit. Each panel's LED
  sits in the title band over the meter and glows with the meter level.
- **An image texture** (`examples/rack/badge.zig`). `init` generates a 32 by 32 RGBA badge,
  creates a texture for it, and queues its pixels; each title band draws it as a `draw.Image`.
- **Layers.** Hovering a knob for `tooltip_delay_ms` (500 ms) shows a tooltip that covers the
  neighbouring knob's name. It is drawn on the overlay layer, so it covers the base layer's
  text batch; test "the tooltip box covers the neighbour's text on the overlay layer" locks it.
- **Procedural meters** (`examples/rack/levels.zig`). Integer-period triangle waves sampled
  from the clock: no trigonometry, no `f64`. Sampling never reads knobs, and dragging a knob
  never changes a bar. Sample values are locked by the test in `levels.zig`.
- **Timer-driven redraw.** `config.timer_period_ms` is `levels.meter_period_ms`, so the
  host calls `App.timer` to resample the meters.

Knob interaction: a knob draws a track arc and, unless its value is at the minimum, a value
arc. Dragging vertically adjusts the value in proportion to `-dy` (up increases). Wheel over
a visible knob ring nudges it the same way instead of scrolling. `Meter.set_value` returns
false when the value is unchanged, and drawing only reads `value`. The scale factors are
`widgets` constants checked by "knob drag is relative and clamped".

### 2. Scroll Column (`examples/column/app.zig`)

A regression app for a single docked `Scroll` container beside a root column. It demonstrates:
- **No timer.** `config.timer_period_ms = 0`, so the native host sleeps in `poll` with the
  timer descriptor disabled and the browser host arms no `setInterval`. An idle app uses no CPU.
- **Scroll ownership.** `Scroll` owns up to `widgets.scroll_child_cap` controls. The scene
  captures the scroll container, and the scroll arbitrates `press` between no target, a child
  index, and the thumb.
- **Unscrolled storage.** Child rects are stored unscrolled; drawing and hit testing subtract
  `scroll_y`. Children outside the viewport are culled from the draw pools, and children that
  cross the viewport edge carry the viewport clip rect.
- **Thumb.** Its height is the viewport-to-content ratio of the viewport height, floored at
  `widgets.thumb_min_px`, and hidden when nothing can scroll. Thumb drag maps absolute pointer
  travel onto the scroll range. Wheel elsewhere in the viewport adds `dy` to `scroll_y`;
  horizontal wheel is ignored.

The docked rectangle's coordinates at specific window sizes are locked by the layout tests
in `examples/column/app.zig`.

## GPU Command Stream

Zig records every GPU operation into a fixed `commands.CommandBuffer` (64 KiB) and both hosts
replay it: native through `gpu_wgpu.execute`, the browser through `submit_js(ptr, len)` in
`web/shell.js`. The hosts contain no WGSL, vertex layouts, or pipeline descriptions;
`draw/renderer.zig` records them.

```text
Renderer.setup  (once, after device creation)
  layout_create  buffer_create  sampler_create  bind_group_create (frame)
  per draw type: shader_create (labelled with the type)  buffer_create  pipeline_create
  buffer_write (unit quad)  per queued texture: texture_create  bind_group_create
  texture_write* (the app's images; the glyph atlas starts empty)
Renderer.frame  (every presented frame)
  buffer_write (uniform, if the device size or scale changed)
  queued texture ops (the glyph cache's dirty atlas rectangle, one strided texture_write)
  buffer_write* (pools)
  pass_begin  bind_group_set 0  vertex_buffer_set 0
  per batch: [pipeline_set vertex_buffer_set 1] [bind_group_set 1] draw
  pass_end_present
```

Each op is an 8-byte header `{ code, size, pad }` followed by an `extern struct` payload,
8-byte aligned. Memory is referenced by `Span { address, len }`, valid for the duration of the
submit. Resources are `u16` ids that Zig allocates and each host maps to its own handle table.
The op table (codes, names, sizes, and every field's offset and type) is generated at compile
time as `commands.table_json`. The wasm module exports it, so `shell.js` decodes payloads by
name and cannot drift from the Zig layouts. Load the page with `?trace=1` to log the op names
of every submitted stream.

The renderer keeps a shadow of each pool's last upload. The uniform (projection from the device
size and scale, see `draw.ortho_y_down`) is written only when those change. A pool whose
revision moved is compared record by record with its shadow, and only the changed range is
written. A frame the host did not draw writes nothing, an identical rebuild writes nothing, a
hover writes the changed arc records only, and a scale change writes the uniform, the new atlas
rectangle, and the glyph range, but no box or arc record. Pipeline, vertex
buffer, and texture bind group sets are skipped when the previous batch already set them. The
exact op sequences are locked by the tests in `src/draw/renderer.zig` and "rack frames record
the step 13 op sequences" in `examples/rack/app.zig`.

## Draw Types, Layers, and Batches

A draw type is an `extern struct` plus a WGSL `fn pixel(px: Pixel) -> vec4<f32>`. The app
lists its types and pool capacities in `config.draw`; the library provides `draw.Box` (fill,
border, radius, hover, down), `draw.Arc` (open ring), `draw.Glyph` (glyph-atlas text written by
`text.place`), and
`draw.Image` (an `rgba8` texture), and an app adds its own (the rack's `Led`).

- **Instance convention.** The first `vec4` is `rect` (x, y, width, height in logical
  pixels), the second is `clip` (exclusive-max x0, y0, x1, y1), and up to six parameter groups
  follow. Every field is `f32` or `[4]f32`, the size is a multiple of 16, and each 16 bytes is
  one `float32x4` attribute at locations 1 to 8. `app.check` fails the build naming the type
  otherwise (`zig build test-contract` locks one case).
- **WGSL assembly.** `draw/registry.zig` concatenates `draw/prelude.wgsl` (the `Frame`
  uniform, a shared `vs_main`, an `fs_main` that applies the clip mask, and `coverage`,
  `stroke`, `sdf_box`, `sdf_circle`, `sdf_segment`, `sdf_arc`), a `Theme` struct generated from
  `theme.Theme`, the per-type `Instance`, `Varyings`, and `Pixel` structs, and the type's
  `pixel`. Derivatives and `textureSample` must stay in uniform control flow, so `pixel`
  must not call them inside branches on instance data; the prelude guide explains.
- **Pools and layers.** `cx.append(T, texture, instance)` writes to `T`'s pool on the current
  layer (`cx.layer(.overlay)` returns the previous layer for restoring). A full pool or batch
  list refuses the instance and counts it in `cx.overflow_count`.
- **Sticky batches.** At frame end each pool is stably sorted by (layer, texture) with a
  counting sort, skipped when appends were already in order, and each (layer, type, texture)
  run is one draw call. Layers draw in order; within a layer, batches draw in order of first
  appearance. Box, glyph, box, glyph in one layer is two draw calls, not four.
- **Textures.** `textures.create(.r8 | .rgba8, width, height)` returns a `TextureId` and
  `textures.write(id, region, bytes)` queues pixels (`write_strided` takes a row stride, for a
  sub-rectangle of a larger image); both are recorded into the next stream, each texture with
  its own bind group. The glyph atlas is texture 0.
- **Clip mask.** Shaders evaluate an analytic hard clip mask instead of scissor state:

```text
pos = rect.xy + local
inside = step(clip.x, pos.x) * step(clip.y, pos.y) * step(pos.x, clip.z) * step(pos.y, clip.w)
alpha = pixel(px).a * inside
```

There is no unclipped sentinel: chrome and panel faces use the window rect, while panel
children use the panel border box clip.

The uniform buffer (`draw.uniform_bytes`) stores the 4x4 projection matrix first and the
`Theme` record (`src/theme.zig`) after it, shared by every pipeline through one bind group.
Colors live in instances and in the theme's lighten, darken, and arc slots, never in WGSL
literals.

Memory: each pool holds `cap` records plus a renderer shadow of the same size, and one scratch
buffer of the largest pool backs the counting sort. The context also holds the glyph cache
(about 1.25 MiB: the 1 MiB atlas mirror, the table, and raster scratch). The hosts keep the
context and renderer in static memory (BSS on wasm), so the linker sizes the wasm initial
memory to cover them.

## Text

`patchwork.text` draws three embedded faces: `.sans` (Noto Sans Regular), `.sans_bold` (Noto
Sans Bold), and `.mono` (Noto Sans Mono Regular), all SIL OFL 1.1 (`src/text/fonts/OFL.txt`).
Both targets `@embedFile` them, so the browser fetches no font files and a project using
`addApp` gets them with the library. The TrueType tables are parsed at compile time.

```zig
const style: text.Style = .{ .face = .mono, .size = 16, .color = .{ 1, 1, 1, 1 } };
const width = text.measure(style, "0.50");                    // logical px, pure
const options: text.Options = .{ .align_x = .center, .align_y = .center, .ellipsis = false };
text.place(cx, style, "0.50", rect, clip, options);
text.place_runs(cx, &runs, rect, clip, options);              // one baseline for mixed styles
```

- **UTF-8** with U+FFFD for each invalid byte; at most `text.byte_cap` (4096) bytes per call.
  A codepoint a face does not map draws its `.notdef` box. No kerning, shaping, ligatures,
  right-to-left, colour fonts, fallback chains, hinting, or subpixel antialiasing.
- **Rasterized on demand at device size.** The draw context's glyph cache rasterizes each
  (face, glyph, size in quarter device pixels) the first time a frame draws it, with exact
  signed-area coverage, into a 1024 by 1024 `r8` atlas (texture 0), and uploads the new region
  as one strided `texture_write` per frame. Glyph origins snap to the device pixel grid and
  UVs sit on exact texel edges, so text is crisp at every scale, fractional ones included.
- **Bounded frames.** At most `text.cache.budget` (256) new glyphs are rasterized per frame;
  the rest are skipped and the host draws again on the next frame. A full atlas resets at the
  start of the next frame; a frame that starts on an empty atlas and still overflows counts
  the overflow instead of resetting again. A settled frame calls no draw, rasterizes nothing,
  and writes nothing.
- **Hosts draw when the cache owes it:** `App.draw` runs when `app.dirty()` or
  `context.text.owes_draw(scale_120)` (the scale changed, or glyphs are pending).

Module guides in `src/text.zig` and `src/text/*.zig` hold the algebra; the tests hold the
worked numbers (the rasterizer is checked against a polygon-clipping reference).

## Platform Hosts

### Native Linux (Wayland + wgpu-native)

GPU code links **wgpu-native v29.0.1.1**. The official Linux x86_64 release archive
is declared as a package dependency in `build.zig.zon`, downloaded automatically by
Zig's package manager, and cached in `~/.cache/zig/p/`.

The event loop in `src/host/linux_window.zig` (`Host(App)`) implements the libwayland
multi-thread reader protocol integrated with an optional Linux `timerfd`:
- `poll` descriptor set: `fds[0]` is the Wayland display socket, and `fds[1]` is `timer_fd`.
  When `App.config.timer_period_ms == 0`, `timer_fd` is -1 (`no_timer_fd`), which `poll`
  ignores. The thread sleeps indefinitely while idle.
- When `timer_period_ms != 0`, the timer wakes the thread to sample values via `drain_timer`
  calling `App.timer(now_ms)`.
- Frame pacing during gestures: each commit requests `wl_surface.frame` and
  `wp_presentation.feedback`. The `presented` event carries the pageflip time and the
  output's refresh period; the next commit is scheduled `present_margin_ns` before the vblank
  projected from it, and that commit draws the pointer sample that has arrived. Without
  `wp_presentation` the `done` receipt is the anchor instead. The swapchain prefers mailbox
  when the surface offers it. The rationale, the Mesa/compositor behavior behind it, and the
  conditions for removing the workaround are in `src/host/linux_window.zig`,
  `src/host/gpu_wgpu.zig`, and `src/host/wp_presentation.zig`.
- Display scale: with both `wp_fractional_scale_manager_v1` and `wp_viewporter` the host is
  in fractional mode. `preferred_scale` arrives in 1/120 units (`Frame.scale_120`), the
  buffer is `round(logical * scale_120 / 120)` device pixels, the buffer scale stays 1, and
  `wp_viewport.set_destination` maps it onto the logical surface size. Without them the
  integer `wl_surface.preferred_buffer_scale` is used (`scale_120 = factor * 120`). The active
  mode is logged once at startup. Pointer coordinates are logical in both modes.
- GPU setup: after `gpu.create` makes the device, the host submits the renderer's setup
  stream. The device's uncaptured-error callback is installed, so a validation error fails the
  frame with the op index, the op name (with the draw type's label for a shader), and the
  driver message instead of aborting.

### Browser (WebAssembly + WebGPU)

In the browser host (`src/host/web_exports.zig` and `web/shell.js`):
- `start()` initializes static Wasm state (the draw context and renderer live in BSS) without
  heap allocation, then initializes the app before recording the setup stream.
- `web/shell.js` invokes `arm_timer()`, querying `wasm.timer_period_ms()`. When 0, no interval
  is set. When non-zero, it runs a `setInterval` calling `wasm.timer(now_ms)`. If `timer` returns
  1, `shell.js` schedules a single `requestAnimationFrame`.
- When rAF runs, `wasm.tick(now_ms)` advances continuous animators and presents dirty frames.
  `wasm.tick()` returns 1 while an interactive animator is moving (`App.live()`) or a redraw
  is still owed (glyphs the cache skipped). Once hover/down animators settle, `tick()` returns
  0 and rAF stops. A resting pointer does not chain animation frames.
- CSS pixels are logical pixels. `fit_canvas` calls `wasm.resize(css_width, css_height,
  round(devicePixelRatio * 120))`, then sizes the canvas backing store from `wasm.width_px()`
  and `wasm.height_px()`, so the device size has one source of truth (`Frame`). A
  `matchMedia` resolution query re-fits the canvas when the ratio changes. Pointer
  coordinates and wheel deltas reach `wasm.pointer_*` in CSS pixels, unscaled, so the layout
  is the same logical size at every device pixel ratio.
- `start()` submits the renderer's setup stream; `shell.js` runs each setup op in a
  `pushErrorScope("validation")` and reports a failure with its op index and name.
- `present_frame()` records a frame into a static `CommandBuffer` and calls `submit_js` once.
  JavaScript decodes the stream and its spans in place, with no intermediate copies, and
  asserts that `pass_begin` carries the canvas backing size.
