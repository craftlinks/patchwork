# Patchwork

A Zig 0.17.0 library copying Makepad's drawing model: plain widget structs that lay
themselves out with a turtle while they draw, record hit areas as they go, and paint with
instanced signed-distance shaders.
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
    pub fn event(app: *App, cx: *patchwork.app.Context(App), event: patchwork.input.Event) void
    pub fn timer(app: *App, cx: *patchwork.app.Context(App), now_ms: u64) void
    pub fn draw(app: *App, cx: *patchwork.app.Context(App)) void
};
```

### Contract Declarations

| Declaration | Signature | Description |
|---|---|---|
| `config` | `Config` | `title`, `timer_period_ms`, `draw` (types and capacities), `batch_cap`, `area_cap`. |
| `init` | `fn (*App, *draw.Textures) void` | Called once before any other call; may create textures. |
| `event` | `fn (*App, *Context(App), Event) void` | Routes pointer, wheel, and `frame` events to the app's widgets. |
| `timer` | `fn (*App, *Context(App), u64) void` | Called on host timer expiration. |
| `draw` | `fn (*App, *Context(App)) void` | Lays out and appends every instance, recording hit areas. |

`Context(App)` is the UI context (`patchwork.ui.Context`): the draw context (`cx.draw`), the
turtle stack, the hit areas of the last frame, and pointer, hover, and capture state. There
is no layout call and no dirty or live query: `cx.redraw()` marks a draw as owed, and
`cx.keep_animating()` (called by a widget whose animator is still moving) keeps frame
callbacks coming. A window resize only marks a draw as owed, because layout happens while
drawing.

The contract is validated at compile time by `patchwork.app.check(App)`. Missing or
mistyped declarations, a draw type that breaks the instance convention (the message names
the type), a zero capacity, a `batch_cap` whose worst frame would not fit one command
buffer, and an `area_cap` outside 1 to 65536 produce a clear `@compileError` naming the
exact problem.

Widgets (`patchwork.widgets`) are plain structs the app owns: `Panel`, `Label`, `Button`,
`Toggle`, `Slider`, `Knob`, and `Meter`. Each draws with `draw(cx, walk)` and, when
interactive, answers `handle(cx, event)` with an action such as `Knob.Action.changed`.
Events resolve once per event against the areas of the last frame, so `handle` is O(1) per
widget; the app routes every event to every widget it owns.

## Repository Layout

```text
patchwork/
├── src/                        # Core library module ("patchwork")
│   ├── root.zig                # Library entry point; re-exports modules and host
│   ├── app.zig                 # App contract definitions and comptime check
│   ├── ui.zig                  # UI namespace: dispatch, animate, draw_frame, re-exports
│   ├── ui/turtle.zig           # Pure layout math: Walk, Size, Layout, Flow, fit, alignment
│   ├── ui/areas.zig            # Id, Area, the hit resolve scan, duplicate-id stamps
│   ├── ui/cx.zig               # UI Context: draw context, turtle stack, areas, hover, capture
│   ├── ui/view.zig             # Scrolling views (ViewState, scrollbar) and the virtual List
│   ├── widgets.zig             # Widgets (Panel, Label, Button, Slider, Knob, Meter, Toggle)
│   ├── draw.zig                # Drawing namespace: projection, unit quad, dirty ranges, re-exports
│   ├── draw/registry.zig       # DrawType, instance convention check, WGSL assembly, layouts
│   ├── draw/prelude.wgsl       # Shared vs_main, fs_main, coverage, clip mask, distance fields
│   ├── draw/types.zig          # Library draw types (Box, Arc, Glyph, Image) and CPU twins
│   ├── draw/pools.zig          # Context: per-type pools, layers, counting sort, sticky batches
│   ├── draw/textures.zig       # Textures: queued creates and writes, TextureId
│   ├── draw/renderer.zig       # Records setup and frame command streams (pipelines, uploads, draws)
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
│   ├── gpu/table.golden.json   # Committed copy of the op table; a test pins it byte for byte
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
│   └── column/                 # Scrolling view regression app
│       └── app.zig             # Column App (config.timer_period_ms = 0)
├── web/                        # Browser harness
│   ├── index.html              # WebGPU canvas host page
│   └── shell.js                # Generic command interpreter, Wasm bridge, and input handler
└── test/                       # Regression tests
    ├── contract_missing_draw.zig # Test verifying that missing draw fails compilation
    └── contract_ragged_type.zig  # Test verifying that a 36-byte draw type fails compilation
```

## Build Steps

Use the distro `zig` (`/usr/bin/zig` on this machine; Zig 0.17.0).

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

`zig build` installs into `zig-out/`:

```text
zig-out/
├── bin/rack, bin/column        # native executables, RUNPATH $ORIGIN/../lib
├── bin/rack.wasm, column.wasm  # from `zig build wasm` and `zig build wasm-column`
└── lib/libwgpu_native.so       # from the wgpu_native package, or from -Dwgpu-lib-dir
```

The executables find `libwgpu_native.so` through `$ORIGIN/../lib`, so they start from any
working directory as long as `bin/` and `lib/` stay siblings. `zig build run` runs the
installed copy, not the one in `.zig-cache`.

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

`steps.install` puts `<name>` in the consumer's `<prefix>/bin` and `libwgpu_native.so` in
`<prefix>/lib`; `steps.run` depends on both and runs the installed executable. Keep the two
directories together when shipping the native build.

### 3. `src/app.zig`

The consumer's app root satisfies the contract:

```zig
const std = @import("std");
const patchwork = @import("patchwork");
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const theme = patchwork.theme;
const quads = patchwork.draw;

const Context = patchwork.app.Context(App);

pub const App = struct {
    gain: widgets.Knob,
    /// Times the knob reported a new value.
    changes: u32,

    pub const config: patchwork.app.Config = .{
        .title = "synth",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 8 },
            .{ .type = quads.Arc, .cap = 8 },
            .{ .type = quads.Glyph, .cap = 64 },
        },
        .area_cap = 8,
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.gain = widgets.Knob.init(ui.id("gain", 0), "gain", 0.5, widgets.accents[0]);
        app.changes = 0;
    }

    pub fn event(app: *App, cx: *Context, input: patchwork.input.Event) void {
        switch (app.gain.handle(cx, input)) {
            .changed => app.changes += 1,
            .none, .released => {},
        }
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const panel: widgets.Panel = .{ .paint = widgets.paint_of(theme.chrome.panel, 8) };
        var layout = ui.flow_of(.down);
        layout.padding = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 };
        _ = panel.begin(cx, ui.sized(.fill, .fill), layout);
        app.gain.draw(cx, ui.sized(.{ .fixed = 144 }, .{ .fixed = widgets.knob_height }));
        _ = cx.end();
    }
};

// Static, like the hosts' context, so the pools stay off the stack.
var context: Context = undefined;

test "a draw records the knob and a wheel turns it" {
    context.init();
    var app: App = undefined;
    App.init(&app, &context.draw.textures);
    try std.testing.expect(ui.draw_frame(App, &app, &context, 400, 300, 120));
    try std.testing.expect(!context.dirty);
    try std.testing.expect(context.draw.items(quads.Arc).len >= 1);
    const ring = context.find(app.gain.id).?.rect;
    const wheel: patchwork.input.Wheel = .{ .x = ring[0] + 28, .y = ring[1] + 28, .dy = -60 };
    ui.dispatch(App, &app, &context, .{ .wheel = wheel });
    try std.testing.expectEqual(@as(f32, 1), app.gain.value);
    try std.testing.expectEqual(@as(u32, 1), app.changes);
    try std.testing.expect(context.dirty);
}

comptime {
    patchwork.app.check(App);
}
```

## Layout While Drawing

`App.draw` lays out as it draws (`src/ui.zig`, `src/ui/cx.zig`): `cx.begin(walk, layout)`
opens a container, children place themselves with `cx.walk(walk)`, and `cx.end()` closes it.
Nesting is the call structure; the stack holds at most 32 open containers.

- **Layout** (on the container): `flow` (`.right`, `.down`, or `.overlay`), `spacing`,
  `padding`, `alignment` per axis, and `clip`, which intersects everything inside with the
  container's box.
- **Walk** (on the child): `width`, `height`, and `margin`. A `Size` is `fixed`, `fill` (on
  the main axis, what remains at placement, so a second fill gets 0), `share(n)` (one n-th of
  the inner span minus spacing: `n` siblings tile it exactly), or `fit` (containers only:
  resolved at `end` from the children's extent).
- **Alignment after the fact.** A container records each draw pool's count and the area
  count when it opens. At `end`, main-axis alignment and a fit child's own alignment each
  yield one delta, snapped to the device pixel grid so glyphs stay crisp, added to `rect.xy`
  of exactly the instances and areas drawn since. A zero delta does nothing; clips never
  move, so a shifted container may not contain a clipping one (asserted).
- **Hit areas.** Widgets record `cx.area(id, rect, radius, flags)` while drawing. Ids are
  `ui.id("name", index)`: a compile-time FNV-1a hash mixed with the index. Each event
  resolves the topmost area once (highest layer, then last drawn; clip and rounded rect must
  contain the point); `cx.hit(id, event)` is then an O(1) compare yielding `hover_in`,
  `hover_out`, `down`, `drag`, `up`, or `wheel`. A press captures until release, across
  frames. The wheel goes to the topmost wheel-flagged area, so a knob inside a view turns
  instead of scrolling. After a draw that moved things under a resting pointer, hover is
  re-resolved and lands one frame late.
- **Views and lists.** `cx.begin_view(id, walk, layout, *ViewState)` clips its children to
  the viewport, starts them `scroll_y` above it, measures their height at `cx.end_view()`,
  and draws the scrollbar thumb from that same frame's height. `ui.List.visible` turns the
  offset into the rows under the viewport; the app skips the others with `cx.skip`, so a
  1,000-row list costs only its visible rows.

All of it is fixed storage with no allocation; per-frame work is proportional to the
instances, areas, and nesting depth drawn, never to capacities. A display scale change does
not change layout; the hosts still redraw once because glyphs are rasterized and snapped at
the device scale, and only the glyph records change (see Text below).

## Example Applications

Worked coordinates, initial values, palettes, and budgets live in the examples' tests, not
here, so they cannot drift. Run `zig build test` for the checked numbers.

### 1. Synthesizer Rack (`examples/rack/app.zig`)

A modular rack under a header bar: a column of panels, each holding a row of knobs and a
level meter, beside a scrolling list of 1,000 presets and a status line. It demonstrates:
- **Layout while drawing.** Nested `begin` and `end` with `share(3)` panels; the knob and
  meter omission rules are a few lines against `cx.remaining()` and `cx.fits()`. The worked
  layouts are locked by the tests in `examples/rack/app.zig`.
- **Actions.** Knobs return `changed`, which the rack writes to its status line
  ("filter.cut changed 0.42"); clicking a preset row selects and highlights it ("preset 412
  selected").
- **Virtual list.** The preset list draws only the rows under its viewport; the view's
  height is capped so the pools hold the worst case at any window size.
- **Text.** The header shows a 32 px monospace "121.00" and a bold "BPM" sharing one baseline
  (`text.place_runs`) and the label "Jürgen Köhler · Café" (composite and non-ASCII glyphs),
  right-aligned and cut with an ellipsis when the bar is narrow. Panel titles are bold 14 px,
  and knob values are monospace (`widgets.value_style`).
- **Clipping.** Panels are clipping containers, so knob faces and titles clip to their panel;
  the meter sits in its own clipping cell so its fixed-height track cannot cover the title.
- **Per-instance accents.** Knob accents are per-instance colors (`draw.Arc.color`), not theme
  slots. The palette is `widgets.accents`.
- **An app-defined draw type** (`examples/rack/led.zig`). `Led` is an `extern struct` plus a
  WGSL `pixel` function, registered in `config.draw` with no library edit. Each panel's LED
  sits in the title band over the meter and glows with the meter level.
- **An image texture** (`examples/rack/badge.zig`). `init` generates a 32 by 32 RGBA badge,
  creates a texture for it, and queues its pixels; each title band draws it as a `draw.Image`.
- **Layers.** Hovering a knob for `tooltip_delay_ms` (500 ms) shows a tooltip that covers the
  neighbouring knob's name. It is drawn on the overlay layer and records no hit area, so it
  never takes the hover from the knob; test "the tooltip box covers the neighbour's text on
  the overlay layer" locks it.
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

A regression app for one scrolling view in a panel docked on the right of the window. It
demonstrates:
- **No timer.** `config.timer_period_ms = 0`, so the native host sleeps in `poll` with the
  timer descriptor disabled and the browser host arms no `setInterval`. An idle app uses no CPU.
- **A view of mixed rows.** Knobs, a meter, and toggles flow down in `cx.begin_view`. Rows
  outside the viewport are culled from the draw pools and record no area; rows that cross
  its edge carry the viewport clip.
- **Thumb.** Its height is the viewport-to-content ratio of the viewport height, floored at
  `ui.view.thumb_min_px`, and hidden when nothing can scroll. Thumb drag maps absolute
  pointer travel onto the scroll range. A wheel elsewhere in the viewport scrolls; a wheel on
  a knob ring turns the knob.

The docked panel's coordinates at specific window sizes are locked by the layout tests in
`examples/column/app.zig`.

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
name and cannot drift from the Zig layouts. A test pins its bytes to
`src/gpu/table.golden.json`, so a toolchain upgrade that changed the table would fail
`zig build test`. Load the page with `?trace=1` to log the op names of every submitted stream.

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
  layer (`cx.draw.layer(.overlay)` returns the previous layer for restoring). A full pool or
  batch list refuses the instance and counts it in `cx.draw.overflow_count`.
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
memory to cover them. The UI context around the draw context adds `area_cap` 48-byte hit
areas, 32 turtle entries, and, in safe builds only, a duplicate-id table of 12 bytes per slot
(`2 * area_cap` rounded up to a power of two).

## Text

`patchwork.text` draws three embedded faces: `.sans` (Noto Sans Regular), `.sans_bold` (Noto
Sans Bold), and `.mono` (Noto Sans Mono Regular), all SIL OFL 1.1 (`src/text/fonts/OFL.txt`).
Both targets `@embedFile` them, so the browser fetches no font files and a project using
`addApp` gets them with the library. The TrueType tables are parsed at compile time.

```zig
const style: text.Style = .{ .face = .mono, .size = 16, .color = .{ 1, 1, 1, 1 } };
const width = text.measure(style, "0.50");                    // logical px, pure
const options: text.Options = .{ .align_x = .center, .align_y = .center, .ellipsis = false };
text.place(cx.drawing(), style, "0.50", rect, clip, options);  // during App.draw
text.place_runs(cx.drawing(), &runs, rect, clip, options);    // one baseline for mixed styles
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
- **Hosts draw when the cache owes it:** `App.draw` runs when `cx.dirty` or
  `cx.draw.text.owes_draw(scale_120)` (the scale changed, or glyphs are pending).

Module guides in `src/text.zig` and `src/text/*.zig` hold the algebra; the tests hold the
worked numbers (the rasterizer is checked against a polygon-clipping reference).

## Platform Hosts

### Native Linux (Wayland + wgpu-native)

GPU code links **wgpu-native v29.0.1.1**. The official Linux x86_64 release archive
is declared as a package dependency in `build.zig.zon`, downloaded automatically by
Zig's package manager, cached in `~/.cache/zig/p/`, and copied into the project's `zig-pkg/`
(gitignored). `addApp` installs the library into `<prefix>/lib` next to the executables.

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
  `wasm.tick()` returns 1 while a widget keeps animating (`cx.keep_animating()`) or a redraw
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
