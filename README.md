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
│   ├── font.zig                # Embedded font atlas (512x256), metrics, GlyphList
│   ├── animator.zig            # Scalar animator transitions (Animator, Clock)
│   ├── frame.zig               # Presentation and damage policy (Frame)
│   ├── input.zig               # Pointer events and bounded EventQueue
│   ├── theme.zig               # 192-byte theme uniform tail
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
│   ├── rack/                   # Modular synthesizer rack (3 panels, 12 knobs, 3 meters)
│   │   ├── app.zig             # Rack App implementing the patchwork.app contract
│   │   └── levels.zig          # Procedural triangle-wave meter sampling
│   └── column/                 # Scroll column regression app (Scroll with 11 children)
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
zig build serve           # Serve the rack WebGPU application on http://127.0.0.1:8080/

# Examples (Scroll Column)
zig build run-column      # Build and run the scroll column natively
zig build wasm-column     # Compile the scroll column to zig-out/bin/column.wasm
zig build serve-column    # Serve the scroll column WebGPU application on http://127.0.0.1:8080/

# Validation
zig build test            # Run unit tests across the library and both examples (111 tests)
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

Layout executes in two bounded passes with zero heap allocation (`child_cap = instance_cap - 1`,
allowing up to 255 child walks alongside container background quads in the 256-instance draw list).
Window resize sets `Frame.relayout`, rebuilding the instance list. A display scale change
leaves `Frame.relayout` false, presenting the new physical framebuffer without re-walking
the column or bumping instance revisions.

## Example Applications and Worked Numbers

### 1. Synthesizer Rack (`examples/rack/app.zig`)

The rack example lays out a modular rack of three panels in a full-window column with
16 px outer padding:
- Panels: Oscillator (`osc`), Filter (`filter`), and Amplifier (`amp`).
- Panel walk: `width = .fill`, `height = .fill`, `align_x = 0`. First panel has `margin.top = 0`;
  the next two have `margin.top = 8`.
- At 1280 x 720: each panel is 224 tall:
  - `osc`: (16, 16, 1248, 224)
  - `filter`: (16, 248, 1248, 224)
  - `amp`: (16, 480, 1248, 224), bottom edge 704
- At 800 x 600: each panel is 184 tall:
  - `osc`: (16, 16, 768, 184)
  - `filter`: (16, 208, 768, 184)
  - `amp`: (16, 400, 768, 184), bottom edge 584
- Panel padding is 8 px on all sides. The title band is 24 px at the top of the inner rect
  (`place_label` centers the title in the panel, then layout sets label height to 24 px).
- The panel body starts below the title band. A knob row of height 72 px sits at the top of
  the body, packed left-to-right by `turtle.place_row`:
  - Four knob cells: `margin.left = 8`, `width = .fixed(144)`, `height = .fixed(72)`,
    `align_x = 0`. Four cells cost 608 px (`4 * 144 + 4 * 8 = 608`).
  - At 1280 x 720: the `osc` body is (24, 48, 1232, 184). First knob cell is (32, 48, 144, 72).
    First knob ring is (40, 56, 56, 56). Meter cell is (1176, 48, 80, 184), and its 144 px track
    is (1206, 68, 12, 144).
  - At 800 x 600: first knob ring is (40, 56, 56, 56). Meter cell is (696, 48, 80, 144), and
    its 144 px track fills the body height.
- Knob faces clip to the parent panel. Meter faces clip to the meter cell, so the 144 px
  track cannot cover the title. A knob or meter whose box does not fit is omitted rather than
  drawn over its neighbor. Panel faces carry the window clip.
- Knobs (12) and initial values:
  - `osc`: `rate` 0.25, `fine` 0.50, `wave` 0.75, `mix` 0.00 (active value arc omitted at 0).
  - `filter`: `cut` 0.50, `res` 0.25, `env` 0.50, `key` 1.00.
  - `amp`: `gain` 0.50, `pan` 0.50, `atk` 0.25, `rel` 0.75.
- Knob accents cycle purple `(0.62, 0.45, 0.86)`, green `(0.40, 0.78, 0.48)`, orange
  `(0.93, 0.55, 0.24)`, and yellow `(0.93, 0.80, 0.32)` by knob index.
- Meters (3) have an empty name `""`. The cell is 80 px wide so the side-label box still has
  positive width, and zero glyphs are emitted.
- Procedural meter levels (`examples/rack/levels.zig`): triangle waves with integer periods and
  phase offsets: `osc` (2000 ms, phase 500 ms), `filter` (3000 ms, phase 750 ms), `amp` (4000 ms,
  phase 1000 ms). No trigonometry, no `f64`. At `now_ms = 0` all meters evaluate to 0.5. At
  500 ms the first bar is 1.0; at 1500 ms it is 0.0; at 750 ms the second bar is 1.0. Sampling
  does not read knobs, and dragging a knob never changes a bar.
- Why the rack is a flat widget list: `demo_count = 18`, `widget_cap = 32`. The scene array
  scans back to front on hit tests; later slots win, so rings and meters win over their backing
  panel without introducing nested containers or duplicating `Scroll` dispatch.
- Faces on the first frame: 32 (3 panels + 23 arcs [12 track arcs + 11 value arcs] + 6 meter
  faces). Dragging `mix` off 0 makes 33.
- Glyphs on the first frame: 100 (12 title letters + 40 name letters + 48 value letters).
  The worst-case budget assertion is `3*8 + 12*8 + 12*4 = 168 <= 256`. Caps stay 256.

Knobs render two `kind_arc` faces on a 56 x 56 ring: a dark track using `theme.track`
(sweep fraction 1.0) and an active value arc using a colorful accent. The active arc is
omitted when value is 0.0. Dragging vertically adjusts value by `-dy / 120.0` (dragging up
increases value). Mouse wheel over a visible knob ring nudges that knob by `-dy / 120.0`
without scrolling. Knob accents are per-instance fills, not theme slots. The meter is a passive
12 x 144 column with an upward-growing fill; `Meter.set_value` returns false when unchanged, and
drawing only reads `value`.

### 2. Scroll Column (`examples/column/app.zig`)

The scroll column example retains the Step 8 single-scroll column architecture, locking
scroll regression tests and behaviors:
- Root container column with 16 px outer padding.
- Docked 320 px `Scroll` container parked on the right: `width = .fixed(320)`, `height = .fill`,
  `align_x = 1`.
  - At 1280 x 720: the scroll rectangle is `(944, 16, 320, 688)`.
  - At 800 x 600: the scroll rectangle is `(464, 16, 320, 568)`.
- `config.timer_period_ms = 0`: because the scroll column has no procedural animations or timers,
  the native host sleeps in `ppoll` with `fds[1]` set to -1 (0.0% CPU idle), and the browser host
  arms no `setInterval`.
- Contains 11 scroll children (`widgets.scroll_child_cap = 16`): panel, buttons, sliders, knobs,
  meter, and toggles.
- `Scroll` owns `[16]Control` (`src/widgets.zig`). The scene captures the scroll container, and
  the scroll arbitrates `press`: `.none`, `.child(i)`, or `.thumb`. Stored child rects are
  unscrolled; drawing and hit testing subtract `scroll_y`. Non-overlapping children are culled
  from draw lists. Partially visible straddlers carry the viewport clip rect. The scrollbar
  thumb height is `max(24, viewport_h * viewport_h / content_h)` (hidden when `max_scroll == 0`),
  and thumb drag maps absolute pointer travel to `[0, max_scroll]`. Wheel elsewhere in the
  viewport scrolls the content column by adding `dy` to `scroll_y`. Horizontal wheel is ignored.

## GPU Pipeline and Memory Layouts

Both `Instance` and `Glyph` records are 64 bytes (`instance_stride = 64`, `glyph_stride = 64`).
The instance buffer is 256 * 64 = 16,384 bytes, and the glyph buffer is 256 * 64 = 16,384 bytes.
The static unit quad vertex buffer remains **48 bytes** (6 vertices * 2 floats * 4 bytes).
In both instance formats, the fourth `float32x4` attribute at byte offset 48 (shader location 4)
is the exclusive-max clip rectangle `(clip_x0, clip_y0, clip_x1, clip_y1)`. `kind` selects the
primitive (`kind_box = 0`, `kind_arc = 1`). Shaders evaluate an analytic hard clip mask:

```text
pos = rect.xy + local
inside = step(clip.x, pos.x) * step(clip.y, pos.y) * step(pos.x, clip.z) * step(pos.y, clip.w)
alpha = fill.a * coverage * inside
```

There is no unclipped sentinel: chrome and panel faces use the window rect, while panel
children (knobs and meters) use the panel border box clip.

The 256-byte uniform buffer stores the 64-byte 4x4 matrix at offset 0 followed by a 192-byte
`Theme` record at offset 64 (`src/theme.zig`). `Theme` holds 12 `vec4` slots: panel, text,
track, value, control, meter, lighten (white), darken (black), arc angles, and 3 zero pads.
`arc.x` is start angle `2pi/3` (7 o'clock); `arc.y` is sweep `3pi/2` (270 degrees). `quad.wgsl`
branches on `kind` (box vs arc), mixes toward theme lighten/darken, reads arc angles from the
uniform (no WGSL color or angle literals), and applies the clip mask. `glyph.wgsl` shares the
same 256-byte Frame uniform view and applies the same clip mask.

## Platform Hosts

### Native Linux (Wayland + wgpu-native)

GPU code links **wgpu-native v29.0.1.1**. The official Linux x86_64 release archive
is declared as a package dependency in `build.zig.zon`, downloaded automatically by
Zig's package manager, and cached in `~/.cache/zig/p/`.

The event loop in `src/host/linux_window.zig` (`Host(App)`) implements the libwayland
multi-thread reader protocol integrated with an optional Linux `timerfd`:
- `poll` descriptor set: `fds[0]` is the Wayland display socket, and `fds[1]` is `timer_fd`.
  When `App.config.timer_period_ms == 0`, `timer_fd` is -1 (`no_timer_fd`), which `poll`
  ignores. The thread sleeps indefinitely while idle (0.0% CPU).
- When `timer_period_ms != 0` (e.g. 33 ms for the rack), the timer wakes the thread to sample
  values via `drain_timer` calling `App.timer(now_ms)`.
- Frame pacing during gestures: each commit requests `wl_surface.frame` and
  `wp_presentation.feedback`. The `presented` event is the pageflip time and the
  output's refresh period; the next commit is scheduled 3 ms before the vblank
  projected from it, and that commit draws the pointer sample that has arrived.
  Without `wp_presentation` the `done` receipt is the anchor instead. The swapchain uses
  mailbox when the surface offers it. Measured on Hyprland 0.56 at 60 Hz, a commit
  reaches the screen about 2.6 ms after it is sent, and 348 of 377 presents in a
  continuous hover sweep were one refresh apart. Details are in `src/host/linux_window.zig`,
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
