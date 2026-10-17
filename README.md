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
    pub const config: patchwork.app.Config = .{ .title = "...", .timer_period_ms = 0 };
    pub fn init(app: *App) void
    pub fn layout(app: *App, width_logical: u32, height_logical: u32) void
    pub fn event(app: *App, event: patchwork.input.Event) bool      // true: dirty
    pub fn timer(app: *App, now_ms: u64) bool                      // true: dirty
    pub fn live(app: *const App) bool
    pub fn dirty(app: *const App) bool
    pub fn draw(app: *App, list: *DrawList, glyphs: *GlyphList) void
};
```

### Contract Declarations

| Declaration | Signature | Description |
|---|---|---|
| `config` | `Config` | Settings: `title` (`[:0]const u8`), `timer_period_ms` (`u32`). |
| `init` | `fn (*App) void` | Called once at startup before any other call. |
| `layout` | `fn (*App, u32, u32) void` | Positions widgets for logical `(w, h)` on size change. |
| `event` | `fn (*App, Event) bool` | Applies pointer/frame events; returns true if dirty. |
| `timer` | `fn (*App, u64) bool` | Called on host timer expiration; returns true if dirty. |
| `live` | `fn (*const App) bool` | True while an animator is moving; gates frame callbacks. |
| `dirty` | `fn (*const App) bool` | True when `draw` is owed; cleared by `draw`. |
| `draw` | `fn (*App, *DrawList, *GlyphList) void` | Rebuilds GPU quads and glyphs back-to-front. |

The contract is validated at compile time by `patchwork.app.check(App)`. Missing or
mistyped declarations produce a clear `@compileError` naming the exact problem.

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
│   ├── draw.zig                # Instanced quad drawing, DrawList, distance fields, UploadCursor
│   ├── turtle.zig              # 2D turtle layout engine (place_column, place_row, Walk, Size)
│   ├── font.zig                # Embedded font atlas, metrics, GlyphList
│   ├── animator.zig            # Scalar animator transitions (Animator, Clock)
│   ├── frame.zig               # Presentation and damage policy (Frame)
│   ├── input.zig               # Pointer events and bounded EventQueue
│   ├── theme.zig               # Theme uniform record packed behind the projection matrix
│   ├── gpu.zig                 # Cross-platform GPU abstraction seam
│   ├── serve.zig               # Built-in static HTTP server for browser testing
│   ├── quad.wgsl               # Instanced quad shader (SDF rounded boxes and ring arcs)
│   └── glyph.wgsl              # Instanced glyph text shader
├── src/host/                   # Platform host implementations generic over App
│   ├── native_main.zig         # Native executable entry point: runs linux_window.run(app.App)
│   ├── web_main.zig            # Wasm entry point: calls web_exports.export_app(app.App)
│   ├── linux_window.zig        # Linux Wayland event loop, timerfd, and Host(App)
│   ├── web_exports.zig         # Wasm exports and zero-copy FFI bridge via @export
│   ├── gpu_wgpu.zig            # Native wgpu-native pipeline and swapchain
│   ├── wl_seat.zig             # Wayland seat and pointer listener
│   ├── wl_callback.zig         # Wayland frame completion callback
│   ├── wp_presentation.zig     # Wayland presentation-time feedback listener
│   └── xdg_shell.zig           # XDG shell surface and toplevel protocol
├── examples/                   # Example applications
│   ├── rack/                   # Modular synthesizer rack
│   │   ├── app.zig             # Rack App implementing the patchwork.app contract
│   │   └── levels.zig          # Procedural triangle-wave meter sampling
│   └── column/                 # Scroll column regression app
│       └── app.zig             # Column App (config.timer_period_ms = 0)
├── web/                        # Browser harness
│   ├── index.html              # WebGPU canvas host page
│   └── shell.js                # WebGPU pipeline compiler, Wasm bridge, and input handler
└── test/                       # Regression tests
    └── contract_missing_draw.zig # Test verifying that missing draw fails compilation
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
zig build test-contract   # Verify compile error when an app is missing `draw`
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

const Widget = union(enum) { panel: widgets.Panel, knob: widgets.Knob };
const Scene = patchwork.ui.Scene(Widget, 2);
const none: turtle.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

pub const App = struct {
    scene: Scene,

    pub const config: patchwork.app.Config = .{ .title = "synth", .timer_period_ms = 0 };

    pub fn init(app: *App) void {
        app.scene = Scene.init(2);
        const c = theme.chrome.panel;
        app.scene.widgets[0] = .{ .panel = .{
            .id = 1,
            .rect = none,
            .padding = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 },
            .walk = .{ .margin = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, .width = .fill, .height = .fill, .align_x = 0 },
            .label = .{ .text = "synth", .rect = none, .r = 1, .g = 1, .b = 1, .a = 1 },
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

    pub fn draw(app: *App, list: *patchwork.draw.DrawList, glyphs: *patchwork.font.GlyphList) void {
        list.clear();
        glyphs.clear();
        const w: f32 = @floatFromInt(app.scene.width_logical);
        const h: f32 = @floatFromInt(app.scene.height_logical);
        const clip: patchwork.font.Clip = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        app.scene.widgets[0].panel.draw(list, glyphs, clip);
        app.scene.widgets[1].knob.draw(list, glyphs, clip);
        app.scene.finish_draw();
    }
};

test "layout then draw is clean" {
    var app: App = undefined;
    App.init(&app);
    app.layout(400, 300);
    try std.testing.expect(app.dirty());
    var list = patchwork.draw.DrawList.init();
    var glyphs = patchwork.font.GlyphList.init();
    app.draw(&list, &glyphs);
    try std.testing.expect(!app.dirty());
    try std.testing.expect(list.count >= 3);
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
`DrawList.append` rejects it to protect the GPU from degenerate quads.

Layout executes in two bounded passes with zero heap allocation. `turtle.child_cap` is derived
from `draw.instance_cap` so every child walk still has room for its container background quad in
one draw list. Window resize sets `Frame.relayout`, rebuilding the instance list. A display scale
change leaves `Frame.relayout` false, presenting the new physical framebuffer without re-walking
the column or bumping instance revisions.

## Example Applications

Worked coordinates, initial values, palettes, and budgets live in the examples' tests, not
here, so they cannot drift. Run `zig build test` for the checked numbers.

### 1. Synthesizer Rack (`examples/rack/app.zig`)

A modular rack in a full-window column: a stack of panels, each holding a row of knobs and a
level meter. It demonstrates:
- **Flat widget list.** One `Scene` array holds panels, knobs, and meters. Hit testing scans
  back to front and later slots win, so a knob or meter wins over its backing panel without
  nested containers. The slot and instance budgets are `comptime` asserts in `app.zig`.
- **Clipping.** Knob faces clip to the parent panel and meter faces clip to the meter cell,
  so a track cannot cover the title. A knob or meter whose box does not fit is omitted rather
  than drawn over its neighbor. Panel faces carry the window clip.
- **Per-instance accents.** Knob accents are per-instance fills (`Instance.fill`), not theme
  slots. The palette is `widgets.accents`.
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
  `scroll_y`. Children outside the viewport are culled from draw lists, and children that
  cross the viewport edge carry the viewport clip rect.
- **Thumb.** Its height is the viewport-to-content ratio of the viewport height, floored at
  `widgets.thumb_min_px`, and hidden when nothing can scroll. Thumb drag maps absolute pointer
  travel onto the scroll range. Wheel elsewhere in the viewport adds `dy` to `scroll_y`;
  horizontal wheel is ignored.

The docked rectangle's coordinates at specific window sizes are locked by the layout tests
in `examples/column/app.zig`.

## GPU Pipeline and Memory Layouts

`Instance` and `Glyph` records share one stride (`draw.instance_stride`, `font.glyph_stride`),
and `comptime` asserts in `draw.zig` and `font.zig` check their field offsets against the
vertex attributes in `gpu_wgpu.zig`, `web_exports.zig`, and the WGSL structs. The static unit
quad is `draw.quad_bytes`. In both instance formats the last `float32x4` attribute is the
exclusive-max clip rectangle `(clip_x0, clip_y0, clip_x1, clip_y1)`. `kind` selects the
primitive (`draw.kind_box`, `draw.kind_arc`). Shaders evaluate an analytic hard clip mask:

```text
pos = rect.xy + local
inside = step(clip.x, pos.x) * step(clip.y, pos.y) * step(pos.x, clip.z) * step(pos.y, clip.w)
alpha = fill.a * coverage * inside
```

There is no unclipped sentinel: chrome and panel faces use the window rect, while panel
children use the panel border box clip.

The uniform buffer (`draw.uniform_bytes`) stores the 4x4 projection matrix first and the
`Theme` record (`src/theme.zig`) after it. The size is a multiple of WebGPU's minimum uniform
offset alignment so both pipelines bind one shared bind group. `quad.wgsl` branches on `kind`,
mixes toward the theme's lighten and darken slots, reads arc angles from the uniform (no WGSL
color or angle literals), and applies the clip mask. `glyph.wgsl` reads the same uniform view
and applies the same clip mask. The exact `Theme` slot order is enforced by `comptime` asserts
in `theme.zig` and the test "wgsl declarations match the Zig layouts".

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

### Browser (WebAssembly + WebGPU)

In the browser host (`src/host/web_exports.zig` and `web/shell.js`):
- `start()` initializes static Wasm state without heap allocation.
- `web/shell.js` invokes `arm_timer()`, querying `wasm.timer_period_ms()`. When 0, no interval
  is set. When non-zero, it runs a `setInterval` calling `wasm.timer(now_ms)`. If `timer` returns
  1, `shell.js` schedules a single `requestAnimationFrame`.
- When rAF runs, `wasm.tick(now_ms)` advances continuous animators and presents dirty frames.
  `wasm.tick()` returns 1 only while an interactive animator is moving (`App.live()`). Once
  hover/down animators settle, `tick()` returns 0 and rAF stops. A resting pointer does not
  chain animation frames.
- Pointer coordinates from DOM events are scaled by `window.devicePixelRatio` before calling
  `wasm.pointer_move`, `pointer_down`, `pointer_up`, and `pointer_wheel`.
- In `present_frame()`, `draw.PresentHeader` is allocated directly on Zig's call stack;
  JavaScript reads dimensions, flags, and linear memory pointers synchronously via `present_js()`
  with zero intermediate heap copying.
