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
| `config` | `Config` | `title`, `timer_period_ms`, `timer_armed`, `draw` (types and capacities), `batch_cap`, `area_cap`, `point_cap`, `theme` (see Theme). |
| `init` | `fn (*App, *draw.Textures) void` | Called once before any other call; may create textures. |
| `event` | `fn (*App, *Context(App), Event) void` | Routes pointer, wheel, key, paste, window focus, and `frame` events to the app's widgets. |
| `timer` | `fn (*App, *Context(App), u64) void` | Called on host timer expiration while the timer runs. |
| `draw` | `fn (*App, *Context(App)) void` | Lays out and appends every instance, recording hit areas. |
| `scenarios` (optional) | `[]const bench.Scenario` | Scripted runs for `--bench` (see Bench Mode). |
| `Audio` (optional) | a type with `init(*Audio, u32)` and `render(*Audio, *realtime.Block)` | An audio source the host runs off the UI thread (see Audio Data). |
| `audio` (with `Audio`) | `fn (*App, *Context(App), *const realtime.Block) void` | Receives every block of the source, in order, on the UI thread. |

`Context(App)` is the UI context (`patchwork.ui.Context`): the draw context (`cx.draw`), the
turtle stack, the hit areas of the last frame, and pointer, hover, and capture state. There
is no layout call and no dirty or live query: `cx.redraw()` marks a draw as owed, and
`cx.keep_animating()` (called by a widget whose animator is still moving) keeps frame
callbacks coming. So does an animated draw type on screen (see Animated Types), with no call
at all; the app stops it by not drawing it. A window resize only marks a draw as owed, because layout happens while
drawing.

**Timer.** With `timer_period_ms` nonzero the host timer runs from startup when
`timer_armed` is true (the default); `cx.set_timer(on)` starts and stops it from `event` or
`timer`, and the hosts arm or disarm it after each call (a `timerfd_settime` natively,
`setInterval` and `clearInterval` in the browser), so a stopped timer wakes nothing. Calling
`set_timer` on an app without a period is an assertion failure.

**Audio.** An app with an `Audio` source starts with it stopped; `cx.set_audio(on)` starts and
stops it, and the hosts apply the change after the call (see Audio Data below).

The contract is validated at compile time by `patchwork.app.check(App)`. Missing or
mistyped declarations, a draw type that breaks the instance convention (the message names
the type), a zero capacity, a `batch_cap` whose worst frame would not fit one command
buffer, an `area_cap` outside 1 to 65536, a `point_cap` outside 1 to 65536, and a
`config.theme` color component outside `[0, 1]` produce a clear `@compileError` naming the
exact problem (`App.config.theme.colors.panel: a component is outside [0, 1]`). `point_cap` (default 65,536) sizes the path
point pool, which exists only when a registered type reads points (`draw.Path`).

Widgets (`patchwork.widgets`) are plain structs the app owns: `Panel`, `Label`, `Button`,
`Toggle`, `Slider`, `Knob`, `Meter`, `TextField`, the popups (`Menu`, `ContextMenu`, `Dropdown`,
`Tooltip`), and the containers and value boxes (`Tabs`, `Splitter`, `ListBox`, `NumberBox`);
the code editor
(`patchwork.editor.Editor`, see Code Editor below) follows the same contract. Each draws with `draw(cx, walk)` and,
when interactive, answers `handle(cx, event)` with an action such as `Knob.Action.changed`.
Events resolve once per event against the areas of the last frame, so `handle` is O(1) per
widget; the app routes every event to every widget it owns.

### Events

`patchwork.input.Event` is one of:

| Event | Payload |
|---|---|
| `pointer_move` | `Point{x, y}` in logical pixels |
| `pointer_down`, `pointer_up` | `Button{x, y, time_ms, button: .left/.right/.middle, mods}` |
| `pointer_leave` | none |
| `wheel` | `Wheel{x, y, dx, dy}` |
| `key_down`, `key_up` | `KeyPress{key, mods, repeat, len, text: [4]u8}`: the typed text rides on `key_down` |
| `paste` | `[]const u8`, valid only while it is dispatched |
| `window_focus` | `bool`: false releases held keys and modifiers |
| `frame` | the animator step in milliseconds |

`Key` names arrows, Home, End, Page Up and Down, Backspace, Delete, Enter, Tab, Escape, `a`
to `z`, `0` to `9`, and F1 to F12 after the user's layout; anything else is `other`. `Mods` is
shift, ctrl, alt, and meta (Command on a Mac); shortcuts use ctrl or meta. Text is dropped
under ctrl or meta and for control characters. Click counting is the library's: presses of
one button at most 400 ms and 4 logical pixels apart count up (`Press.clicks`).

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
│   ├── ui/canvas.zig           # Pan/zoom canvases: CanvasState, the zoom ladder, wheel and drag
│   ├── ui/edit.zig             # Editing core: bounded UTF-8 field, caret, words, sanitizing
│   ├── ui/popup.zig            # Popup placement: place (side, flip, clamp, cut), Anchor
│   ├── widgets.zig             # Widgets namespace: re-exports every widget and constant
│   ├── widgets/kit.zig         # The widget kit: append, face, arc, label, step, aim, weight,
│   │                           #   clicked, Interaction, Paint, the hover and press constants
│   ├── widgets/skin.zig        # Skins: the look structs, Shape, skins.check, skins.Default
│   ├── widgets/label.zig       # One file per widget, with its constants, geometry, and tests:
│   ├── widgets/panel.zig       #   Label, Panel, Button, Slider, Knob (and the shared ring and
│   ├── widgets/button.zig      #   label-column geometry, accents), Meter, Toggle, TextField
│   ├── widgets/slider.zig
│   ├── widgets/knob.zig
│   ├── widgets/meter.zig
│   ├── widgets/toggle.zig
│   ├── widgets/text_field.zig
│   ├── widgets/menu.zig        # Menu and ContextMenu: a list in a popup, keys and pointer
│   ├── widgets/dropdown.zig    # Dropdown: a face showing the selection and its Menu
│   ├── widgets/tooltip.zig     # Tooltip: one line after a hover dwell, on the tooltip layer
│   ├── widgets/tabs.zig        # Tabs: a bar of tabs over a page the app draws
│   ├── widgets/splitter.zig    # Splitter: two panes and a draggable divider, begin/next/end
│   ├── widgets/list_box.zig    # ListBox: a virtual list with selection, keys, scroll-into-view
│   ├── widgets/number_box.zig  # NumberBox: drag, wheel, or type a value with a unit
│   ├── widgets/fixture.zig     # The widget tests' static context and drivers
│   ├── editor.zig              # Code editor namespace: Editor, Style, Decoration, InlineRow
│   ├── editor/buffer.zig       # 64 KiB contiguous text, line index, start states, undo arena
│   ├── editor/tokenizer.zig    # Patch language tokenizer: per-line states, seven classes
│   ├── editor/editor.zig       # The editor widget: grid, view, keys, selection, rows
│   ├── draw.zig                # Drawing namespace: projection, unit quad, dirty ranges, re-exports
│   ├── draw/registry.zig       # DrawType, instance convention check, WGSL assembly, layouts
│   ├── draw/prelude.wgsl       # Shared vs_main, fs_main, coverage, clip mask, distance fields
│   ├── draw/types.zig          # Library draw types (Box, Arc, Glyph, Image, Path) and CPU twins
│   ├── draw/pools.zig          # Context: per-type pools, point pool, layers, sort, batches
│   ├── draw/path.zig           # Stroked paths: flattening, chunking, twins, appenders
│   ├── draw/textures.zig       # Textures: queued creates and writes, TextureId, write revisions
│   ├── draw/tiles.zig          # Pixel cache tiles: hashes, dirty bits, scissor rects, record keys
│   ├── draw/renderer.zig       # Records setup and frame command streams; frame kinds, kept target
│   ├── text.zig                # Text namespace: faces, Style, measure, place, place_runs
│   ├── text/ttf.zig            # Comptime TrueType reader: cmap 12/4, hmtx, glyf, composites
│   ├── text/subset.zig         # Build-time subsetter: glyph closure, renumbered ids, no hinting
│   ├── text/raster.zig         # Quadratic flattening and exact signed-area coverage
│   ├── text/cache.zig          # Glyph cache: hash table, shelf-packed atlas, CPU mirror, budget
│   ├── text/layout.zig         # UTF-8, alignment, ellipsis, device-pixel snapping
│   ├── text/mono.zig           # Monospace grid: per-frame ASCII table, direct glyph appends
│   ├── text/fonts/             # Noto Sans Regular and Bold, Noto Sans Mono (SIL OFL, OFL.txt)
│   ├── animator.zig            # Scalar animator transitions and animation time (Animator, Clock, Time)
│   ├── frame.zig               # Presentation and damage policy (Frame)
│   ├── input.zig               # Events, EventQueue, clicks, key names, text filter, repeat
│   ├── theme.zig               # Scheme (dark, light), its GPU record behind the projection, arc angles
│   ├── gpu.zig                 # Cross-platform GPU seam: create and submit
│   ├── gpu/commands.zig        # GPU command stream: op encoding, decoder, generated op table
│   ├── gpu/table.golden.json   # Committed copy of the op table; a test pins it byte for byte
│   ├── bench.zig               # Bench mode: scenarios, replay, simulated clock, PPM and PNG
│   ├── realtime.zig            # Audio blocks, the SPSC queue, the wake, test tone, meters, scope
│   ├── serve.zig               # Built-in static HTTP server for browser testing
│   └── native_tests.zig        # Test root of tests that call libxkbcommon or spawn threads
├── src/host/                   # Platform host implementations generic over App
│   ├── native_main.zig         # Native entry point: parses options, runs linux_window.run(App)
│   ├── web_main.zig            # Wasm entry point: calls web_exports.export_app(app.App)
│   ├── linux_window.zig        # Linux Wayland event loop, timerfd, audio wake, and Host(App)
│   ├── audio_thread.zig        # Native audio engine: the app's source on a paced thread
│   ├── web_exports.zig         # Wasm exports and zero-copy FFI bridge via @export
│   ├── gpu_wgpu.zig            # Native replayer: id tables, execute, swapchain, headless target
│   ├── headless.zig            # `--regress`: every scenario with no window, against the goldens
│   ├── wl_seat.zig             # Wayland seat, pointer, and keyboard bindings (version 8)
│   ├── xkb.zig                 # libxkbcommon: keymap, modifiers, text, compose, repeat
│   ├── wp_cursor_shape.zig     # wp_cursor_shape_v1 bindings and the cursor shape map
│   ├── wl_data_device.zig      # Clipboard protocol bindings (wl_data_device_manager 3)
│   ├── clipboard.zig           # Clipboard state machine: selection, send and receive pipes
│   ├── wl_callback.zig         # Wayland frame completion callback
│   ├── wp_presentation.zig     # Wayland presentation-time feedback listener
│   ├── wp_fractional_scale.zig # wp_fractional_scale_v1 and wp_viewporter bindings
│   └── xdg_shell.zig           # XDG shell surface and toplevel protocol
├── examples/                   # Example applications
│   ├── rack/                   # Modular synthesizer rack
│   │   ├── app.zig             # Rack App implementing the patchwork.app contract
│   │   ├── led.zig             # The rack's own draw type: a glowing LED
│   │   └── badge.zig           # Procedural 32 by 32 RGBA badge texture
│   ├── column/                 # Scrolling view regression app
│   │   └── app.zig             # Column App (config.timer_period_ms = 0)
│   ├── live/                   # Live-coding screen
│   │   ├── app.zig             # Live App: header, editor, knob column, curves, lanes, transport
│   │   ├── bindings.zig        # Binding parser: k() calls, shape() calls, bpm, fixed point
│   │   ├── knob.zig            # The bound knob: any ring size, value text inside the ring
│   │   ├── lanes.zig           # Transport and automation lanes: in-place rings, playhead
│   │   ├── shaper.zig          # The inline shaper row's transfer curve
│   │   ├── icon.zig            # The live app's own draw type: transport and status icons
│   │   ├── glow.zig            # Its animated draw type: the armed record button's glow
│   │   ├── bench.zig           # The live screen's bench scenarios
│   │   └── patch.lpg           # The embedded patch the editor opens
│   ├── data/                   # Data textures, samplers, and blending
│   │   ├── app.zig             # Data App: float textures, sampling modes, additive and multiply
│   │   └── views.zig           # Its draw types: Heat, Shade, Tile, Bars, Light
│   ├── wave/                   # Waveforms and spectra
│   │   ├── app.zig             # Wave App: overview, zoomable sample view, DJ waveform, spectrogram
│   │   └── track.zig           # The synthetic track, its band envelopes, and the DFT columns
│   ├── fx/                     # Offscreen effects
│   │   └── app.zig             # Fx App: phosphor scope with bloom, a panel faded as one layer
│   ├── audio/                  # Audio data into the UI
│   │   └── app.zig             # Audio App: test tone meters, triggered scope, XY trace
│   ├── canvas/                 # Pan and zoom
│   │   └── app.zig             # Canvas App: a 1,000-module grid with cables, select and drag
│   └── gallery/                # Every library widget on tabbed pages (phases 6 and 7)
│       ├── app.zig             # Gallery App: built only from widgets.kit and layout defaults
│       └── hardware.zig        # A hardware skin: the Dial and Bevel draw types, an Led, Skin
├── tools/
│   ├── compare.zig             # `zig build compare`: how two frames differ; diff and crop PNGs
│   ├── browser_check.py        # A scenario replayed in Chromium against its headless frame
│   └── subset.zig              # The build's font subsetter (runs text/subset.zig on a face)
├── web/                        # Browser harness
│   ├── index.html              # WebGPU canvas host page
│   ├── shell.js                # Generic command interpreter, Wasm bridge, and input handler
│   └── worklet.js              # AudioWorklet processor running the app's source from its wasm
└── test/                       # Regression tests
    ├── golden/<adapter>/<app>.txt # Regress hashes per adapter and driver (`zig build regress`)
    ├── contract_missing_draw.zig # Test verifying that missing draw fails compilation
    ├── contract_ragged_type.zig  # Test verifying that a 36-byte draw type fails compilation
    ├── contract_frozen_time.zig  # Test verifying that reading time without `animated` fails
    ├── contract_audio_without_sink.zig # Test verifying that `Audio` without `audio` fails
    ├── contract_theme_range.zig  # Test verifying that a theme color of 1.5 fails, naming it
    ├── contract_skin_missing.zig # Test verifying that a skin without `knob` fails, naming it
    └── contract_overlays_none.zig # Test verifying that `ui.overlays` of a target without
                                   # any `draw_overlay` fails, naming it
```

## Build Steps

Use the distro `zig` (`/usr/bin/zig` on this machine; Zig 0.17.0). Native builds link
`libwayland-client` and `libxkbcommon` dynamically through pkg-config, so both libraries and
their `.pc` files must be installed (every Wayland desktop ships the libraries); a system
without them refuses to start the executable. The wasm build links nothing.

```bash
# Examples (Rack)
zig build run             # Build and run the synthesizer rack natively (Wayland + wgpu-native)
zig build wasm            # Compile the rack to zig-out/bin/rack.wasm (wasm32-freestanding)
zig build serve           # Serve the rack WebGPU application on localhost (prints the address)

# Examples (Scroll Column)
zig build run-column      # Build and run the scroll column natively
zig build wasm-column     # Compile the scroll column to zig-out/bin/column.wasm
zig build serve-column    # Serve the scroll column WebGPU application on localhost (prints the address)

# Examples (Live-Coding Screen)
zig build run-live        # Build and run the live-coding screen natively
zig build wasm-live       # Compile the live-coding screen to zig-out/bin/live.wasm
zig build serve-live      # Serve the live-coding screen on localhost (prints the address)

# Examples (Data Textures)
zig build run-data        # Build and run the data textures screen natively
zig build wasm-data       # Compile it to zig-out/bin/data.wasm
zig build serve-data      # Serve it on localhost (prints the address)

# Examples (Waveforms and Spectra)
zig build run-wave        # Build and run the wave views natively
zig build wasm-wave       # Compile them to zig-out/bin/wave.wasm
zig build serve-wave      # Serve them on localhost (prints the address)

# Examples (Offscreen Effects)
zig build run-fx          # Build and run the offscreen effects natively
zig build wasm-fx         # Compile them to zig-out/bin/fx.wasm
zig build serve-fx        # Serve them on localhost (prints the address)

# Examples (Audio)
zig build run-audio       # Build and run the audio meters and scope natively (silent)
zig build wasm-audio      # Compile them to zig-out/bin/audio.wasm
zig build serve-audio     # Serve them on localhost; Space plays the tone (audible)

# Examples (Pan and Zoom Canvas)
zig build run-canvas      # Build and run the module canvas natively
zig build wasm-canvas     # Compile it to zig-out/bin/canvas.wasm
zig build serve-canvas    # Serve it on localhost (prints the address)

# Examples (Widget Gallery)
zig build run-gallery     # Build and run the widget gallery natively
zig build wasm-gallery    # Compile it to zig-out/bin/gallery.wasm
zig build serve-gallery   # Serve it on localhost (prints the address)

# Validation
zig build test            # Run unit tests across the library and the nine examples
zig build test-contract   # Verify compile errors for a missing `draw`, a ragged draw type,
                          # a type that reads time without declaring `animated`, an
                          # `Audio` source without `audio`, a theme color of 1.5, a
                          # knob skin without `knob`, and `ui.overlays` of a target
                          # with no `draw_overlay`
zig build check           # Compile every example's shaders and pipelines on a GPU with no
                          # window; fails naming the broken draw type (needs a GPU)
zig build check -- --adapter low   # The same on the integrated GPU
zig build regress -Doptimize=ReleaseFast   # Every example's scenarios headless on both GPUs,
                          # cache on and off, against test/golden (needs a GPU; see Regression)
zig build regress -Doptimize=ReleaseFast -- --bless   # Rewrite the goldens from this run
python3 -I tools/browser_check.py gallery still   # One scenario in Chromium against headless

# Bench mode (see Bench Mode below)
zig build bench-live -Doptimize=ReleaseFast -- typing-stress --adapter low
zig build compare -- a.ppm b.ppm   # Compare two frame dumps; exit 1 when they differ
zig build compare -- a.png b.ppm --crop 0 0 1088 704 --diff d.png   # A rect of both, diff PNG
zig build compare -- a.ppm --crop 0 0 640 360 --png out.png         # A crop of one, as PNG
```

An optional override flag `-Dwgpu-lib-dir=` is available if you wish to link against a
custom unpack directory or local build of `wgpu-native`:

```bash
zig build run -Dwgpu-lib-dir=/path/to/wgpu-native/lib
```

`zig build` installs into `zig-out/`:

```text
zig-out/
├── bin/rack, column, live,     # native executables, RUNPATH $ORIGIN/../lib
│   data, wave, fx, audio,
│   canvas, gallery
├── bin/rack.wasm, column.wasm, # from `zig build wasm`, `zig build wasm-column`,
│   live.wasm, data.wasm,       #   `zig build wasm-live`, `zig build wasm-data`,
│   wave.wasm, fx.wasm,         #   `zig build wasm-wave`, `zig build wasm-fx`,
│   audio.wasm, canvas.wasm,    #   `zig build wasm-audio`, `zig build wasm-canvas`,
│   gallery.wasm                #   and `zig build wasm-gallery`
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
    b.step("bench", "Run a bench scenario").dependOn(steps.bench);
    b.step("test", "Run app tests").dependOn(steps.tests);
    b.getInstallStep().dependOn(steps.install);
}
```

`AppOptions.font_ranges` sets the codepoints the embedded faces keep, on both targets (see
Text). It defaults to `patchwork.default_font_ranges`; pass wider ranges for other scripts,
or `null` for the full faces.

`addApp` links `libwayland-client` and `libxkbcommon` into the native executable, so a
consumer's build machine needs both (with their pkg-config files) as described under Build
Steps. `steps.install` puts `<name>` in the consumer's `<prefix>/bin` and
`libwgpu_native.so` in `<prefix>/lib`; `steps.run` depends on both and runs the installed executable. Keep the two
directories together when shipping the native build.

### 3. `src/app.zig`

The consumer's app root satisfies the contract:

```zig
const std = @import("std");
const patchwork = @import("patchwork");
const ui = patchwork.ui;
const widgets = patchwork.widgets;
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
            .changed, .reset => app.changes += 1,
            .none, .released => {},
        }
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const panel: widgets.Panel = .{ .paint = widgets.paint_of(cx.theme().colors.panel, 8) };
        _ = panel.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down, .padding = .all(16) });
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
    const wheel: patchwork.input.Wheel = .{ .x = ring[0] + 28, .y = ring[1] + 28, .dx = 0, .dy = -60 };
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
  container's box. Only `flow` is required; the rest default to none, so a container opens
  in one statement: `cx.begin(walk, .{ .flow = .down, .spacing = 8, .padding = .all(12) })`.
  `Inset.all(v)`, `Inset.xy(x, y)`, and `Inset.sides(left, top, right, bottom)` build insets.
- **Walk** (on the child): `width`, `height`, and `margin` (none by default; `ui.sized(w, h)`
  is `.{ .width = w, .height = h }`). A `Size` is `fixed`, `fill` (on
  the main axis, what remains at placement, so a second fill gets 0), `share(n)` (one n-th of
  the inner span minus spacing: `n` siblings tile it exactly), or `fit` (containers only:
  resolved at `end` from the children's extent).
- **Alignment after the fact.** A container records each draw pool's count and the area
  count when it opens. At `end`, main-axis alignment and a fit child's own alignment each
  yield one delta, snapped to the device pixel grid so glyphs stay crisp, added to `rect.xy`
  of exactly the instances and areas drawn since. A zero delta does nothing; clips never
  move, so a shifted container may not contain a clipping one (asserted).
- **Hit areas.** Widgets record `cx.area(id, rect, radius, flags)` while drawing, and a stroked
  path records `cx.path_area(id, placed, width, flags)`: the points within `width / 2 + 3` of
  its polyline. Ids are `ui.id("name", index)`: a compile-time FNV-1a hash mixed with the
  index. Each event resolves the topmost area once (highest layer, then last drawn; clip and
  rounded rect, or clip, rect, and polyline distance, must contain the point); `cx.hit(id, event)` is then an O(1) compare yielding `hover_in`,
  `hover_out`, `down`, `drag`, `up`, or `wheel`. A press captures until release, across
  frames. The wheel goes to the topmost wheel-flagged area, so a knob inside a view turns
  instead of scrolling. After a draw that moved things under a resting pointer, hover is
  re-resolved and lands one frame late.
- **Flags.** `cx.area`'s `Flags` carry `wheel`, `focusable` (a left press focuses the area
  and Tab visits focusable areas in draw order), `tab` (while the area is focused, Tab and
  Shift+Tab go to its widget instead of moving focus; the editor indents), and `cursor` (the pointer shape over the
  area: `default`, `pointer`, `text`, `grab`, `grabbing`, `ew_resize`, `ns_resize`). A right
  press on the hot area is `Hit.secondary` and never captures.
- **Routing.** `App.event` calls each widget's `handle`, which is how it learns what changed.
  For widgets whose result it does not need, `ui.route(cx, event, target)` calls every widget
  a target names: a widget, a slice or array of them, or each widget field of a struct (so
  `ui.route(cx, event, app)` cannot forget one). It returns how many acted.
- **Widget sizes.** `widgets.Knob.init(...).sized(40)` sets one knob's ring (the labels follow
  it), and `Meter.track_h` one meter's track; the defaults are the shared constants.
- **Widget kit.** The library widgets are built from `widgets.kit`, which an app's own widget
  uses the same way: `kit.face(cx, rect, clip, look)` appends a `draw.Box` (none for an empty
  rect), `kit.arc` a `draw.Arc`, `kit.label` places text, `kit.append` appends any draw type
  and skips it when its pool is full (the context counts it), `kit.step` and `kit.aim` ease
  animators and owe redraws, `kit.weight` and `Paint.look(hover, down)` turn animator values
  into mix weights, `kit.clicked(cx, id, event)` makes a clickable row (true on a release
  inside, a repaint on hover), and `kit.Interaction` (or `kit.respond` on a widget's own
  animators) is the hover and press table every library widget follows. The records come from
  `draw.Box.of(rect, clip, BoxLook)` and `draw.Arc.of(ring, clip, ArcLook)`, whose looks
  default to no border, hover, or press and the full sweep; `ui` and `draw` use the
  constructors directly. One file per widget lives in `src/widgets/`; `widgets.zig`
  re-exports every name. Each widget is generic over a skin that draws it (`KnobOf(Skin)`;
  see Make a Skin below).
- **Views and lists.** `cx.begin_view(id, walk, layout, *ViewState)` clips its children to
  the viewport, starts them `scroll_y` above it, measures their height at `cx.end_view()`,
  and draws the scrollbar thumb from that same frame's height. `ui.List.visible` turns the
  offset into the rows under the viewport; the app skips the others with `cx.skip`, so a
  1,000-row list costs only its visible rows. `widgets.ListBox` does all of this for uniform
  rows (see Containers and Value Boxes below).

All of it is fixed storage with no allocation; per-frame work is proportional to the
instances, areas, and nesting depth drawn, never to capacities. A display scale change does
not change layout; the hosts still redraw once because glyphs are rasterized and snapped at
the device scale, and only the glyph records change (see Text below).

## Keyboard, Focus, Clipboard, and Cursor

- **Focus.** `cx.focus` is the id that gets keys and pastes; widgets ask `cx.focused(id)`.
  A left press focuses a focusable hot area or clears focus; Tab and Shift+Tab cycle the
  focusable areas of the last frame in draw order (the only O(areas) key path), unless the
  focused area is flagged `tab`; Escape clears focus after the widgets saw it, which is also
  how the keyboard leaves the editor; a press elsewhere or Tab shows as
  `cx.focus_lost(id)` during that event. A focused id that is not drawn stays focused.
- **TextField.** A single-line field of at most 256 bytes: caret, selection, Ctrl or Meta
  with arrows for word jumps, Shift selection, Home and End, double press for a word, triple
  for everything, drag selection, copy, cut, paste (one line, cut to the limit), and
  horizontal scroll that follows the caret. Actions are `changed`, `committed` (Enter or
  losing focus), and `cancelled` (Escape). The caret is steady, so a focused field does not
  wake the host.
- **Clipboard.** `cx.copy(bytes)` hands up to 64 KiB to the host and `cx.request_paste()`
  asks for the clipboard, which arrives as one `paste` event for the focused widget.
- **Cursor.** `cx.cursor()` is the hot area's shape, `grabbing` while a `grab` area is held.
- **Repeat.** Hosts repeat keys (`KeyPress.repeat`); the library never does.

## Theme

The look of the whole app is a value it owns: `theme.Scheme` (`src/theme.zig`).

- **What is themed.** The chrome colors (`colors.panel`, `text`, `track`, `value`, `control`,
  `meter`), the window `background`, the text field's `focus` border and `selection` band,
  `lighten` and `darken` (what hover and press mix toward), four `accents`, the two text
  styles widgets label with (`name`, `value`), and the hover and press weights
  (`hover_lighten`, `down_darken`). Every library widget, the scrollbar thumb, and the clear
  color read it at draw time.
- **What is not.** Sizes (they are per instance: `Knob.sized`, `Meter.track_h`, a `Walk`),
  the open ring's angles (the CPU hit tests use the constants), and colors an app stored in
  a widget (`Button.paint`, `Slider.track`, `Knob.accent`, `Panel.paint`, a style), which
  win; `widgets.kit.accent(cx, i)` gives the scheme's accent for an app that wants it.
- **Presets.** `theme.dark` is the look of steps 1 to 30 and the default; `theme.light` is
  its light counterpart. `theme.chrome` is `dark.record()`, the GPU record.
- **Choosing and switching.** `config.theme` picks the scheme the app starts with;
  `cx.theme()` reads it in any phase; `cx.set_theme(scheme)` in `event` or `timer` switches
  it. A switch is one frame: the renderer writes the 256-byte frame uniform once and repaints
  every tile, and the same scheme again costs nothing.
- **Making one.** Copy a preset and change fields: `var s = theme.dark; s.colors.panel =
  .{ 0.2, 0.1, 0.1, 1 };`. Colors are straight RGBA with components in `[0, 1]`, and text
  sizes are at most `text.size_max`; `app.check` refuses anything else and names the field.

## Make a Skin

A widget's behaviour (its fields, `handle`, and actions) is written once; how it looks and
where it takes presses belong to a skin, a struct of draw functions passed at compile time.
`widgets.Knob` is `widgets.KnobOf(widgets.skins.Default)`; `ButtonOf`, `SliderOf`, `ToggleOf`,
`MeterOf`, `PanelOf`, `TextFieldOf` (its face and border only), `MenuOf`, `DropdownOf`, `TabsOf`,
`SplitterOf`, `ListBoxOf`, and `NumberBoxOf` work the same way. There
is no vtable: two looks on one screen are two types, and `ui.route` routes both.

A knob skin declares one function. It gets a `widgets.KnobLook` of plain values (the row, the
clip, the ring's side, the value and its text, the raw hover value, the accent, the name),
appends whatever it draws, and returns the hit shape the knob records, or null to draw and
record nothing:

```zig
const Skin = struct {
    pub fn knob(cx: anytype, look: widgets.KnobLook) ?widgets.Shape {
        if (look.row.height < look.ring) return null;
        const ring = widgets.ring_sized(look.row, look.ring);
        const body = ui.cx.inset(ring, .all(9));
        kit.append(cx, hardware.Dial, null, .{ ... }); // its own draw type, in config.draw
        kit.arc(cx, ring, look.clip, .{ .color = accent, .thickness = 4, .sweep = look.value });
        kit.label(cx, cx.theme().name, look.name, widgets.name_box(look.row, look.ring), ...);
        return .{ .rect = body, .radius = body.width * 0.5 }; // presses on the body only
    }
};
const HardKnob = widgets.KnobOf(Skin); // init, sized, handle, Action: those of widgets.Knob
```

- **The contract.** `button`, `slider` (with `slider_travel(area) [2]f32`, the x span a press
  maps onto `[0, 1]`), `knob`, `toggle`, `dropdown`, `tab`, `divider`, and `number_face` return
  `?widgets.Shape`; `meter`, `panel`, `field`, `menu_face`, `menu_row`, `tab_bar`, and
  `list_row` return nothing. A number box skin also needs `field`, for its editor. A skin declares only what it skins. `KnobOf(S)` checks `S.knob` and
  fails the build with a message naming the skin and the function, for example
  "hardware.Skin: missing `pub fn knob(cx, widgets.KnobLook) ?widgets.Shape`".
- **Colors** come from `cx.theme()` inside the skin and from the look's paints, so a skin
  follows the app's theme. Animator values arrive raw; apply `scheme.hover_lighten` yourself.
- **Draw order.** A batch draws where its type first appeared in its layer. A skin with its
  own face type should append faces on one layer and what goes on top (arcs, labels) on a
  higher one, then restore the layer, as the gallery's hardware skin does.
- **Check the shaders.** `zig build check` compiles every draw type's WGSL before a window
  opens and names the broken type.

## Popups

Menus, dropdown lists, context menus, dialogs, and tooltips are drawn by the widget that owns
them, last, at the root of the turtle stack, on their own layers (`Layer.popup` 6 and
`Layer.tooltip` 7, above the overlay layer 4 and canvases 1 to 4). The rule is one line at the
end of `App.draw`:

```zig
pub fn draw(app: *App, cx: *Context) void {
    // ... the whole screen ...
    ui.overlays(cx, app); // calls draw_overlay on every field that has one, in field order
}
```

- **Placement.** `ui.popup.place(anchor, size, window, side)` puts a popup `.below`,
  `.above`, `.right`, `.left` of its anchor or `.at` its top-left (a context menu at the
  pointer), 2 px from it and 4 px inside the window; a side that overflows flips when the other
  side has more room, then the box is clamped and, if larger than the window, cut. Widgets take
  `bounds: ?Rect` (null for the window) so placement does not depend on a window size the
  compositor picks.
- **Input.** `cx.begin_popup(id, rect, layout, dim)` records a backdrop area over the whole
  window on the popup layer before the popup's own areas. Resolution already prefers the highest
  layer, then the last appended, so the popup's rows take the pointer over them and the backdrop
  takes it everywhere else: an outside press dismisses and does not also click what was under it.
  The wheel reaches nothing under a popup. `dim` (0 to 1) darkens the screen behind a dialog.
- **Widgets.** `widgets.Menu` (up to 32 items, disabled items, Up/Down/Home/End/Enter/Escape,
  Tab dismisses), `widgets.ContextMenu` (a menu opened by a right press on a target id),
  `widgets.Dropdown` (a face and its menu, `Action.changed` only for a different item), and
  `widgets.Tooltip` (the app says what is hovered as a `widgets.Tip`; it shows after
  `tooltip_delay_ms`, hides on a press, and records no area). `MenuOf(Skin)` and
  `DropdownOf(Skin)` are skinnable like the other widgets.
- **Forgetting `ui.overlays`.** Opening a popup calls `cx.request_popup(id)`; in safe builds
  the next draw panics naming the id if no `draw_overlay` drew it, and `ui.overlays` on a target
  with no overlay at all is a compile error.
- **Idle.** An open menu at rest wakes nothing, and a tooltip's dwell animates only until it
  shows.

## Containers and Value Boxes

`Tabs`, `Splitter`, and `ListBox` keep the turtle's begin/end shape: the library owns the
chrome, the geometry, and the input, and the app draws the content between the calls. No widget
takes a callback, and all four answer `handle(cx, event)`, so `ui.route` reaches them. Each is
skinnable (`TabsOf(Skin)`, and so on; see Make a Skin).

- **Tabs.** A bar of up to 16 tabs over a page the app draws with a `switch`; the tabs own no
  page. Tabs are left-aligned at their labels' widths and shrink evenly to 48 px when the bar is
  narrow, cutting labels with an ellipsis. A press selects (`Action.changed` for a different
  tab); with the bar focused, Left and Right, Ctrl+Tab and Ctrl+Shift+Tab move, wrapping.

  ```zig
  _ = app.tabs.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down });
  switch (app.tabs.selected) {
      0 => app.draw_mixer(cx),
      else => app.draw_settings(cx),
  }
  _ = cx.end();
  ```
- **Splitter.** Two panes (`.horizontal` side by side, `.vertical` stacked) and a 6 px divider
  with minimum pane lengths; pane a is `clamp(round(ratio * span), min_a, span - min_b)`, split
  in proportion when the minimums do not fit. Dragging the divider returns `moved` (the ratio),
  a double click `reset`. Panes are clipped containers, so splitters nest. The order of
  `begin`, `next`, and `end` is asserted.

  ```zig
  _ = app.split.begin(cx, ui.sized(.fill, .fill)); // pane a
  app.draw_browser(cx);
  _ = app.split.next(cx); // the divider, then pane b
  app.draw_inspector(cx);
  app.split.end(cx);
  ```
- **ListBox.** A virtual list of up to 2^20 uniform rows in a scrolling view: only the rows under
  the viewport are walked, each with a derived id, so the app never builds row ids. A click
  returns `selected`, a double click `activated`; with the list focused (Tab reaches it), Up,
  Down, Page Up, Page Down, Home, and End move the selection and scroll it into view, and Enter
  activates. The skin draws the band under each row; the app draws the row's content.

  ```zig
  _ = app.presets.begin(cx, ui.sized(.fill, .fill));
  while (app.presets.next(cx)) |row| {
      kit.label(cx, style, name_of(row.index), row.rect, row.clip, start);
  }
  app.presets.end(cx);
  ```
- **NumberBox.** An `f64` in `[min, max]` with a step (0 for continuous) and a format (decimals
  and a unit such as " Hz"). A vertical drag covers the range in 200 px (Shift a tenth, Ctrl or
  Meta ten times), the wheel moves one step, a right press resets, and a double click opens a
  `TextField` with the value selected: Enter parses it (an optional sign, digits, a fraction;
  anything else keeps the old value), clamps it, and returns `committed`, Escape cancels.
  `widgets.format_number` and `widgets.parse_number` are pure, use no `std.fmt`, and work in
  the wasm build.

  ```zig
  app.gain = widgets.NumberBox.init(ui.id("gain", 0), 0, -60, 12, 0.1, .{ .decimals = 1, .unit = " dB" });
  app.gain.draw(cx, ui.sized(.fill, .{ .fixed = 32 })); // in draw
  switch (app.gain.handle(cx, event)) { // in event
      .changed, .committed => |db| app.engine.set_gain(db),
      .none => {},
  }
  ```

## Example Applications

Worked coordinates, initial values, palettes, and budgets live in the examples' tests, not
here, so they cannot drift. Run `zig build test` for the checked numbers.

### 1. Synthesizer Rack (`examples/rack/app.zig`)

A modular rack under a header bar: a column of panels, three holding a row of knobs and a
level meter and the fourth four envelope knobs and an envelope display, with patch cables
between knobs, beside a scrolling list of 1,000 presets and a status line. It demonstrates:
- **Layout while drawing.** Nested `begin` and `end` with `share(4)` panels; the knob and
  meter omission rules are a few lines against `cx.remaining()` and `cx.fits()`. The worked
  layouts are locked by the tests in `examples/rack/app.zig`.
- **Actions.** Knobs return `changed`, which the rack writes to its status line
  ("filter.cut changed 0.42"); a right click resets a knob to its initial value
  ("filter.cut reset 0.50"); clicking a preset row selects and highlights it ("preset 412
  selected"), and once the list has focus the arrow, page, Home, and End keys move the
  selection.
- **Renaming.** A double click on a panel title opens a `TextField` in its place with the
  name selected; Enter or a click elsewhere commits ("osc renamed vco"), Escape cancels, and
  copy and paste work with other apps. Knob rings show the grab cursor and the field the
  I-beam.
- **Virtual list.** The preset list is a `widgets.ListBox` in the rack's own skin (its
  selected band is the first accent); it draws only the rows under its viewport, and the view's
  height is capped so the pools hold the worst case at any window size. Test "the preset list
  draws the records of the rack's own list" checks that the move onto `ListBox` changed no
  record.
- **Text.** The header shows a 32 px monospace "121.00" and a bold "BPM" sharing one baseline
  (`text.place_runs`) and the label "Jürgen Köhler · Café" (composite and non-ASCII glyphs),
  right-aligned and cut with an ellipsis when the bar is narrow. Panel titles are bold 14 px,
  and knob values are monospace (`widgets.value_style`).
- **Clipping.** Panels are clipping containers, so knob faces and titles clip to their panel;
  the meter sits in its own clipping cell so its fixed-height track cannot cover the title.
- **Per-instance accents.** Knob accents are per-instance colors (`draw.Arc.color`), not theme
  slots. The palette is `widgets.accents`.
- **An app-defined draw type** (`examples/rack/led.zig`). `Led` is an `extern struct` plus a
  WGSL `pixel` function, registered in `config.draw` with no library edit. Each voice panel's
  LED sits in the title band over the meter and glows with the meter level.
- **An image texture** (`examples/rack/badge.zig`). `init` generates a 32 by 32 RGBA badge,
  creates a texture for it, and queues its pixels; each title band draws it as a `draw.Image`.
- **Patch cables.** The center of each knob's ring is a jack hub. Dragging from a hub draws a
  preview cable to the pointer; releasing over another knob patches a cable ("osc.rate ->
  filter.cut"; at most 16, no self links or duplicates). Cables are translucent sagging
  cubics (`draw.path.cubic`) on layer 2, above the panels and text and below the tooltip;
  hovering one lightens it and a right press removes it ("cable removed") instead of
  resetting the knob under it. A cable also keeps the wheel from the knob under its stroke.
  Two cables exist at start.
- **Envelope.** The env panel's attack, decay, sustain, and release knobs shape a 64-point
  envelope drawn with `draw.path.polyline`. Hovering the display runs a playhead dot along
  it, advanced on every displayed frame (the display's refresh rate) through
  `cx.keep_animating()`; leaving the display stops the frames.
- **Layers.** Hovering a knob for `tooltip_delay_ms` (500 ms) shows a `widgets.Tooltip` that
  covers the neighbouring knob's name. It is drawn on the tooltip layer by `ui.overlays` and
  records no hit area, so it never takes the hover from the knob; test "the tooltip box covers
  the neighbour's text on the tooltip layer" locks it, and "the tooltip draws the records of
  the rack's own tooltip" that its box and text are byte for byte those of the rack's earlier
  hand-made tooltip.
- **Audio-driven meters.** The rack declares `Audio = realtime.TestTone`; Space (when no
  title is being renamed) starts and stops it ("tone on", "tone off"). Each block's L, R, and
  mid peaks go through `realtime.Ballistics` onto the osc, filter, and amp meters, and the
  LEDs follow. Dragging a knob never changes a bar. The rack has no timer: stopped, it draws
  empty meters and sleeps (before step 26 a 30 Hz timer woke it forever). In the browser the
  tone is audible.

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

### 3. Live-Coding Screen (`examples/live/app.zig`)

The code editor on the embedded `examples/live/patch.lpg` beside a column of knobs bound to
its `k(lo~value~hi, "name")` calls, with curves from each value to its knob, an inline shaper
row, automation lanes, and a transport. There is no audio engine and no DSL evaluation: the
values are UI state that lives in the text. It demonstrates:
- **Two-way binding** (`bindings.zig`). A full pass over the buffer from the editor's cached
  tokenizer states finds the calls (comments and strings are skipped), at most 64 bind, and a
  malformed one is an error decoration with a cross in the header. Editing a number moves its
  knob; dragging a knob rewrites the literal with the same decimals (integer fixed point:
  9.99 steps to 10.00, -0.01 to 0.00, `.25` to `.30`), one undo entry per gesture, with the
  original shown struck through in the knob row until release. A drag event is one
  `Editor.replace` and one range shift, never a full pass; keys are dropped while a knob is
  held. A right press resets to the value at load.
- **Curves** on layer 2 from the right edge of each boxed value (`Editor.rect_of`) to its
  ring, clamped to the editor's or the column's edge when an end scrolls out, dimmed away
  from the caret's line.
- **Inline row.** `shape(gain, slope, twice, asymmetry)` gets an inline row (`InlineRow`) of
  four knobs that mirror the bindings of those names and a 64-point transfer curve
  (`shaper.zig`).
- **Lanes and transport** (`lanes.zig`). A 256-sample ring per binding with a sweeping
  playhead; record writes values at the head; play starts the host timer at 30 Hz with
  `cx.set_timer` and pause stops it, so a paused screen sleeps. Each lane is anchored at its
  rect (`path.polyline_at`), so a recorded sample uploads one point.
- **An app-defined draw type** (`icon.zig`): back, play, pause, record, check, and cross.
- **Header.** The file name with `*` while modified, the parse status, the bound count past
  64, a bpm field bound to the `bpm := 121` line, the caret's line:col, and refusals.
- **Stress text.** F2 loads a generated 2,000-line text (2,100 calls, 50 errors), F1 reloads
  the patch. Only visible lines and rows draw.
- **Uploads.** The panel draws before the editor and the header last, so a typed key writes
  the glyphs from the edited line on; tests "uploads of a scrolled frame and a typed key" and
  "transport ticks upload the playhead and one recorded point" lock the byte counts.
- **Record glow** (`glow.zig`). While record is armed, an animated `Glow` breathes around
  the record icon once a second from the frame's time, playing or paused; armed and paused,
  every frame is animation-only. Disarmed and paused, the screen sleeps.
- **Bench scenarios** (`bench.zig`). `idle` (every frame skipped by the pixel cache),
  `pulse` (record armed while paused: animation-only frames), `transport`, `typing`, `transport-stress`, and `typing-stress`, replayed headless by test
  "the bench scenarios replay headless".

### 4. Data Textures (`examples/data/app.zig`)

Four panels at fixed positions from the top-left, so a native frame dump and a browser
screenshot compare region for region: an `r32float` spectrogram sampled `nearest` under a
`multiply` shade, an `rg16float` tile repeated 3x3 with linear filtering, an `r16float` ring
of bars read with `load_texture` from a write head, and three `additive` discs that sum to
white. No input, no timer: it draws once and sleeps. Its `still` scenario dumps the frame.
Natively and in Chromium on the same GPU (RTX 3060) the four panels are bitwise identical;
across the RTX 3060 and the UHD 770 they differ by at most 2/255 (filtering and blending).

### 5. Waveforms and Spectra (`examples/wave/app.zig`)

A 16-second synthetic track (kick, bass, hats, a swell; no asset) in four views at fixed
positions: an overview of the whole track and a sample view with RMS, both `draw.Waveform`
columns from a `wave.Pyramid`; a 3-band DJ waveform, `draw.Ring(.rgba8, ...)`; and a
spectrogram of 128 log-spaced bins, `draw.Ring(.r16float, ...)`. Space plays and pauses (the
timer runs only while playing); each 20 ms tick pushes one column into each ring, and the
next draw flushes them: 4 bytes and 256 bytes per tick. The wheel zooms the sample view
around the pointer, from the whole track to 1/8 sample per column, and a press on the
overview seeks. Scenarios: `still`, `play`, `zoom`. At 2856 by 2514 a playing tick costs
about 37 microseconds of CPU and a cached GPU frame (0.13 to 0.4 ms on the RTX 3060, 1.7 ms
on the UHD 770); the paused screen is bitwise identical natively and in Chromium.

### 6. Offscreen Effects (`examples/fx/app.zig`)

A phosphor scope and a panel faded two ways, at fixed positions. The scope is a feedback
target: each frame its layer draws the target's last frame at 0.88 (less a 1.5/255 bias, so
8-bit trails reach black) and then a Lissajous trace; a horizontal blur of it into a second
target and a vertical blur out with `cover = 0` add a glow. The "one layer" panel is drawn
into a single target and composited at the chosen opacity; the "per instance" panel scales
every instance's alpha, so its overlaps stand out. Clicks step the opacity, Space pauses
the scope (it decays for 44 frames, then the screen sleeps). The scope's clock is drawn
frames, so its pictures are deterministic. At 2856 by 2514 the scope target costs about
11 microseconds of GPU and the glow blur 20 on the RTX 3060 (0.11 and 0.48 ms on the UHD
770), 2.5 MB in all; the panel's target never re-renders when only its opacity changes.
Natively and in Chromium the faded screen is bitwise identical.

### 7. Audio (`examples/audio/app.zig`)

Stereo meters (RMS fill, peak line, and a one-second hold on a 60 dB scale), a scope of 512
frames triggered on L's rising zero crossing, and an XY trace of L against R on a feedback
target with persistence, all fed by `realtime.TestTone` (220 and 330 Hz with slow gain
triangles) through the audio queue, plus a line of blocks received and dropped. Space starts
and stops the tone; stopped, the meters reset, the XY trail decays for 44 frames, and the
screen sleeps. Scenarios: `still` and `play` (the bench feeds 6, 6, 6, 7 blocks per frame on
the UI thread, so dumps are deterministic). At 2856 by 2514 a playing frame costs about 28
microseconds of CPU on the RTX 3060 (41 on the UHD 770) plus 1.6 microseconds per block to
render the tone and 0.4 to drain it; the never-started screen is bitwise identical natively
and in Chromium.

### 8. Pan and Zoom Canvas (`examples/canvas/app.zig`)

A 1,000-module grid (40 by 25, each a face, a header with its title, two ports, and a
`widgets.Knob` with a 40 px ring, all 1,000 routed by one `ui.route` call and draggable at any
zoom) with about 1,300 hanging cables, in a 1248 by 592 canvas. The wheel zooms one
rung (2^(1/4)) about the pointer from 25% to 400%, dragging the background pans, pressing a
module selects it, and dragging its header moves it; arrows pan, `=` and `-` zoom about the
center, and `0` resets. Modules and cables are culled in world pixels, below 50% a module is
its face and header, and text below a 6-pixel on-screen em is not placed, so the zoomed-out
canvas (408 modules visible) places no glyphs. The status line shows the zoom, the offset,
the visible modules and cables, and the glyph cache's epoch, which a full zoom sweep leaves
at 0. Scenarios: `still`, `zoom` (every rung in and out), `pan` (arrow keys), and `zoomed`
(three rungs in and five steps right, for the browser compare).

### 9. Widget Gallery (`examples/gallery/app.zig`)

Every library widget on a fixed 1280 by 704 screen from the top-left, built only from
`widgets.kit` and the one-statement layouts. It is the regression app of phases 6 and 7: a
`widgets.Tabs` bar under the title holds one page per section, and the title bar's status line
shows the last action ("knob 1 changed 0.75"), so the app handles each widget itself rather
than through `ui.route`. A "light" toggle in the title bar switches the whole app between
`theme.dark` and `theme.light` (`cx.set_theme`); the widgets' stored colors (slider paints,
knob accents, the field's text) are restyled from the scheme, while the buttons keep their own
blue.

- **basics** (steps 30 to 32): three buttons, two sliders, four knobs with rings of 56, 40, 56,
  and 72, three toggles, a meter that follows slider 0, a 240 px text field, and a list of 40
  clickable rows (`kit.clicked`) in a view. Under them a hardware row draws four knobs, two
  buttons, and two toggles with the same library behaviour in the gallery's own skin
  (`examples/gallery/hardware.zig`): a `Dial` draw type with a drop shadow and a pointer, a
  `Bevel` face lit on top and shaded below, and the rack's `Led` ("hardware knob 0 changed
  0.83"). Every knob shows a tooltip ("gain 0.25").
- **popups** (step 33, see Popups): a dropdown of six waveforms, a "File" button opening a menu
  (Save as… disabled, About… opening a modal dialog over a dimmed screen), a panel with a
  context menu (Copy, Paste, Reset), and a second dropdown 40 px above the frame's bottom whose
  list opens above it. Popups stay inside the 1280 by 704 frame.
- **containers** (step 34, see Containers and Value Boxes): a horizontal `Splitter` whose left
  pane is a `ListBox` of 1,000 presets ("preset 0001" ...) and whose right pane is a vertical
  splitter of six `NumberBox`es (frequency 20 to 20000 Hz, gain -60 to 12 dB, attack, release,
  q, mix) over a panel naming the selected and the last activated preset.

Scenarios: `still`, `interact` (a click, two drags, a toggle, typing, a wheel, and a row click,
then settled), `hover` (the pointer rests on button 1), `light` (the toggle, then the focused
field with "abc" selected, settled), and `hardware` (hardware knob 0 dragged up 40 px, hardware
button 1 clicked, hardware toggle 0 flipped, settled) on the basics page; `dropdown` (Down twice
and Enter: "dropdown changed 2"), `menu-open`, `menu-flip`, `context` (right click, Reset),
`dismiss` (an outside click closes the menu and opens nothing), `tooltip`, and `about` for the
popups; `tabs` (each tab clicked: the containers page), `split` (the divider dragged 120 px
left), `list` (row 3 clicked, then Down 20 times: preset 0024 scrolled into view), and `number`
(the frequency dragged up 40 px, the gain double-clicked, "-6.5" typed, Enter) for the
containers.

## Pan and Zoom

A canvas draws content in world pixels through a view, `screen = (x, y) + zoom * world`
(`src/ui/canvas.zig`, `src/ui/cx.zig` section 3a):
- **Per-layer views.** `cx.begin_canvas(id, walk, layout, *CanvasState, layers)` gives each of
  its 1 to 4 layers this frame's view (`draw.Context.view`). The renderer draws a viewed layer
  with its own frame uniform whose projection is the window's times the view
  (`draw.view_ortho`), so no record, shader, or op changes: distance fields are evaluated in
  world pixels and `coverage` keeps edges one device pixel wide at any zoom. A pan writes that
  uniform (256 bytes) and whatever entered or left the culled set.
- **World inside, screen outside.** Inside a canvas the clip, the turtle (a root over the
  visible world rect), and `cx.visible` are in world pixels, so culling is the usual cull
  test. Areas are mapped to the screen when recorded (`Area.zoom` keeps a path area's
  polyline in world pixels), so hit testing, capture, and `Press.rect` need no inverse;
  `CanvasState.to_world` maps the pointer back for moving content. `cx.begin_at(rect,
  layout)` places a container at a fixed rect outside its parent's flow (free placement).
- **Zoom ladder.** 17 rungs `2^(k/4)` from 0.25 to 4. The wheel moves one rung about the
  pointer; the offset is snapped to device pixels when drawn. Glyphs rasterize at the rung
  nearest the zoom (`text.Cache.zoom`), so the cache holds at most one size per rung, text is
  pixel-exact on every rung, and a full sweep fits the atlas without a reset.
- **Pixel cache.** A viewed batch maps its bounds through the view and folds the view into
  its key, so a pan or zoom dirties exactly the canvas's tiles; a still canvas is skipped or
  cached like anything else.
- **Paths.** `draw.path.cubic` flattens by the on-screen length (`view_zoom`).

## Audio Data

`patchwork.realtime` (`src/realtime.zig`) carries data from an audio engine into the UI:
- **Blocks.** 128 stereo frames (the Web Audio render quantum), interleaved `f32`, 1 KiB, at
  48 kHz; the producer posts 4 at a time (10.7 ms). `AudioQueue` holds 256 (683 ms).
- **Queue.** A lock-free single-producer, single-consumer ring with `u32` indices on separate
  cache lines. The producer renders into `slot()` and calls `publish()`; the consumer reads
  `peek()` and calls `release()`. A full queue refuses and counts (`dropped`); it never
  blocks or overwrites, so an audio thread is never held up by the UI.
- **Wake.** The producer writes the wake's descriptor only when the consumer armed it before
  sleeping, and the consumer arms only when nothing else will wake it (no frame callback in
  flight, no commit latched). Both sides use `seq_cst` on the flag and the queue head, so a
  block published just before the sleep is never missed. While frames flow the producer
  makes no syscall.
- **Source.** The app's `Audio` runs off the UI thread: natively on a thread paced by
  `clock_nanosleep` at the device rate (there is no audio output yet; a PipeWire sink would
  replace the clock), in the browser in an AudioWorklet (`web/worklet.js`) that instantiates
  the same wasm and calls its `audio_render` export, so the browser plays it. Start and stop
  (`cx.set_audio`) are the only control; no `SharedArrayBuffer` or cross-origin isolation is
  needed.
- **Analysis.** `levels` (peak and RMS of L, R, mid), `meter_of` (60 dB scale), `Ballistics`
  (24 dB/s fall and a one-second hold, counted in blocks), and `Scope` (a history with a
  rising-crossing trigger).
- **Idle.** With the tone stopped the audio thread parks on a futex and the UI thread sleeps
  (about 1 wake per second measured, against 30 for the rack's old timer); playing, the audio
  thread wakes 94 times per second and the UI presents at most once per display frame.

## Bench Mode

`src/bench.zig` and the native host measure frames on request; without `--bench` nothing of
it runs, no GPU feature is requested, and the frame path is unchanged.

```text
<app> [--adapter low|high] [--no-cache] [--check] [--bench [scenario] [--frames N]
      [--dump out.ppm] [--csv out.csv]]
zig build bench-<example> -Doptimize=ReleaseFast -- <scenario> [options]
```

- **Scenarios.** An app declares `pub const scenarios: []const bench.Scenario`: a `setup`
  list run once and a `cycle` list repeated while `frames` frames are measured. Steps are
  `key`, `click` and `click_at` (an area of the last frame, by `bench.area(name, index)`),
  `right_click` (a right press and release at a point, for a context menu), `wheel`, `hover` (a move to a point that stays, so hover animations settle), `drag` (press,
  move by a delta, release; a zero delta is refused), and `wait`. Each step runs when the host is idle and presents one frame; an empty
  cycle measures the frames the app presents itself (a timer). `app.check` validates the
  list, and `bench.replay_headless` replays one in app tests without a GPU. `--bench` without
  a name lists the scenarios. `bench.replay_headless_paced` spaces the steps by a given
  number of milliseconds instead of a second (16 is the regress clock's frame), so two clicks
  on one spot make a double click as they do in `--regress` and the browser replay.
- **Per frame.** `App.draw` (with layout), `finalize`, record (compare and stream), submit
  and present on the CPU; the render pass on the GPU from timestamp queries, read back by
  blocking after present (so profiled frames do not overlap CPU and GPU work); instances
  and shaded area (`rect` intersected with `clip`, in windows) per draw type.
- **Report.** Min, p10, p50, p90, and max per metric, the mode, the adapter's name, and the
  window size; `--csv` writes every measured frame. Compare runs at the same window size: GPU
  time scales with it, and drivers change clock states under light load, so read the minimum
  next to the median.
- **Frames.** `--dump` copies the last measured frame from the swapchain and writes a PPM.
  Two runs of a step-driven scenario (`typing`) give identical dumps; a timer-driven one
  (`transport`) differs where the timer moved things, because how many ticks land during the
  setup varies. `zig build compare` reports differing pixels by size of difference (1, 2,
  3-8, 9-32, 33-255) and exits 1 when any differ.
- **Adapter.** `--adapter low` asks for `low_power` (an integrated GPU), `high` for
  `high_performance`; it works without `--bench` too. `--no-cache` turns the pixel cache off.
- **Check.** `--check` opens no window: it records the app's setup stream (every shader,
  layout, pipeline, and startup resource), replays it on a device created with no surface
  (`bgra8unorm` standing in for the surface format), prints `check: N shaders, M pipelines
  ok (title, adapter)`, and exits; on a WGSL or pipeline error it logs the op, the draw type's
  name, and the message as a frame error would, and exits 1. `zig build check` runs it for
  every example. The browser has no such mode; with `?trace=1` the page logs one "compiled
  shader" line per module from `getCompilationInfo`.
- **Frame kinds.** The report counts measured frames by what the renderer recorded (skipped,
  copied, cached, full, direct); a skipped frame's GPU time is 0, and a cached frame's includes
  the copy to the surface when the adapter supports timestamps inside encoders. `gpu pass` is
  every pass of the frame plus the copy; `gpu target i` is the frame's i-th offscreen target
  pass, and the report ends with each target's device size and memory.
- **Audio.** No thread runs in bench mode: while the app's audio is on, every frame is
  presented and first fed `realtime.blocks_for_frame(n)` blocks (6, 6, 6, 7) rendered on the UI
  thread, so dumps are deterministic. The report adds the blocks, drops, the most drained at
  once, and the render and drain time per block.
- **Browser.** `?bench=1` requests `timestamp-query` and logs pass-time percentiles every 120
  timed passes (`window.patchworkBench` holds the last). `?bench=<scenario>` replays a
  scenario (see Regression).

## Regression

`zig build regress` asks one question of every example: did any picture change? It needs no
window, no master build, and no dumps; the windowed bench stays the tool for timing,
presentation, and the idle invariant.

```text
<app> --regress [--adapter high|low|both] [--bless] [--only scenario] [--keep]
zig build regress -Doptimize=ReleaseFast [-- options]
```

- **Headless.** `--regress` (`src/host/headless.zig`) opens no Wayland connection. Per adapter
  it creates a device with no surface and a `bgra8unorm` target that stands in for the
  swapchain (`gpu_wgpu.headless_target_create`): acquiring returns it, presenting is a no-op,
  so the renderer's stream replays unchanged. Every scenario with `regress = true` (the
  default) renders cache on and off, each from fresh state (app, UI context, renderer, and GPU
  tables re-created), at 1280 x 720 and scale 1 (`pub const regress_size: [2]u32` overrides,
  1 to 4096 a side), and the last frame's RGB rows are hashed (XxHash64, seed 0).
- **Clock.** Frame `n` is at `n * 1000 / 60` ms: the step of that frame, then every app timer
  tick due by then (each at its own multiple of the period), `ui.animate` by 1/60 s, the
  frame's audio blocks (`realtime.blocks_for_frame`), and the draw. Nothing reads wall time,
  so timer and audio scenarios (wave `play`, audio `play`) give the same hash every run.
- **Goldens.** `test/golden/<adapter slug>/<app>.txt` names the adapter, its driver, and the
  size, then one sorted `scenario  hash` line per scenario. A golden blessed on another driver
  is refused before anything renders ("Re-bless from master"); a missing line is `new`.
  `--bless` rewrites the file once cache on and off agree; a step that changes pixels on purpose
  blesses in its own commit and the changed lines are the review.
- **Report.** One table per app, written in one go, and a summary line with the run count and
  the wall time; exit 1 unless every row is `same` and `ok` (or `blessed`). A passing run
  writes nothing. A failing one writes `zig-out/regress/<app>/<scenario>-<adapter>-<cache>.new.png`
  and a diff PNG (dim grey where equal, red by difference) against cache on, or against the
  baseline `<scenario>-<adapter>-on.png` that a `--keep` run on a passing tree leaves.
- **Browser.** `?bench=<scenario>` sets the canvas to the regress size at scale 1 and replays
  the scenario on the same clock (input, the interval timer, and the worklet are off).
  `tools/browser_check.py <app> <scenario>` (standard library only) renders the headless
  frame, serves the app, drives system Chromium over CDP, and compares the screenshot: it
  passes at a maximum difference of 3 levels on at most 0.1% of the pixels, and reports
  console errors.

## GPU Command Stream

Zig records every GPU operation into a fixed `commands.CommandBuffer` (64 KiB) and both hosts
replay it: native through `gpu_wgpu.execute`, the browser through `submit_js(ptr, len)` in
`web/shell.js`. The hosts contain no WGSL, vertex layouts, or pipeline descriptions;
`draw/renderer.zig` records them.

```text
Renderer.setup  (once, after device creation)
  layout_create (frame, filterable and unfilterable texture)  buffer_create
  [buffer_create (points)]  sampler_create (the default mode: linear, clamped)
  bind_group_create (frame: uniform [and points])
  per draw type: shader_create (labelled with the type)  buffer_create  pipeline_create
  shader_create pipeline_create (the clear pipeline of the pixel cache)
  buffer_write (unit quad)  per queued texture: texture_create  [sampler_create (its mode,
  the first time)]  bind_group_create
  texture_write* (the app's images; the glyph atlas starts empty)
Renderer.frame  (every drawn frame)
  buffer_write (uniform, if the device size or scale changed)
  queued texture ops (the glyph cache's dirty atlas rectangle, one strided texture_write)
  buffer_write* (pools)  [buffer_write (points)]
  [buffer_write (uniform time, 16 bytes, while an animated type is on screen)]
  then by the frame's kind (see Pixel Cache):
  direct   pass_begin (surface)  bind_group_set 0  vertex_buffer_set 0
           per batch: [pipeline_set vertex_buffer_set 1] [bind_group_set 1] draw
           pass_end_present
  full     [target_create]  pass_begin (kept target, clear)  every batch  pass_end
           present_copy
  cached   pass_begin (kept target, load)  per dirty rect: scissor_set, the clear
           pipeline's draw, every batch  pass_end  present_copy
  copied   present_copy
  skipped  nothing
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
the step 16 op sequences" in `examples/rack/app.zig`. The path point pool follows the same
rule with its own shadow: a rebuilt path whose shape is unchanged writes no points, and a
recolored one writes its `Path` records only.

### Pixel Cache

Every frame rebuilds every instance, but most frames change a few percent of the window (a
playhead, a caret line). The renderer keeps the last frame in a render target and repaints only
what changed (`src/draw/tiles.zig`, `src/draw/renderer.zig` section 4a):

- **Tiles.** After the uploads, every instance folds a key into each 64-pixel tile its `rect`
  (cut by its `clip`, grown by a pixel) touches, in draw order. The key covers the record's
  bytes and the points it names, mixed with its batch and its texture's write revision (not
  the glyph atlas's, which only grows). Keys are kept per record and recomputed only for
  records and points the upload found changed. A tile whose hash differs from the last frame's
  is dirty; a size, scale, or theme change dirties all.
- **Frames.** No dirty tile: `skipped`, nothing presented; natively the surface still commits a
  frame callback, so animation pacing holds. More than half dirty (scrolling, resize, the first
  frame): `direct`, today's pass on the surface. Otherwise a pass on the kept target: `full`
  (cleared, every batch) when it is stale, else `cached`: loaded, and per merged dirty rect a
  scissor, a clear quad (WebGPU clears only whole attachments), and every batch. Then
  `present_copy` copies the kept target onto the surface. Rects merge down rows and are capped
  per app by `renderer.rects_max` so the worst frame fits one command buffer.
- **Exact.** A scissor does not change any pixel, so a cached frame equals a direct one bit
  for bit: on both GPUs here, `typing` and `typing-stress` dumps with and without `--no-cache`
  are identical.
- **Cost.** At a 2856 by 2514 window, the GPU frame falls from 3.9 to 1.5 ms (`typing`) and
  from 5.7 to 1.7 ms (`typing-stress`) on the UHD 770, and from 0.29 to 0.13 ms and 0.37 to
  0.14 ms on the RTX 3060; most of a cached frame is the full-window copy, which WebGPU cannot
  avoid (no buffer age). Hashing adds about 40 microseconds of CPU per frame, 60 to 90 on the
  stress text.
- **Unchanged frames.** When no pool, point, or texture revision moved and the size held, the
  instances are the last frame's, so the renderer skips hashing and repeats the last frame's
  tiles: an idle frame records in under a microsecond (was about 38).

### Animated Types

A draw type that declares `pub const animated = true` may read the frame uniform's time slot
(`frame.time.x`, seconds, or the prelude's `time_seconds()` and `time_pulse(hz)`). The
uniform is the projection, then the time `vec4` at byte 64, then the theme: 256 bytes. The
registry rejects a type that reads time without the declaration, because the cache would keep
its pixels (`zig build test-contract` locks it). The renderer forces an animated instance's
tiles dirty every frame and reports `animating`, and both hosts then keep presenting and
advance `animator.Time`: whole milliseconds of the clock's clamped deltas, counted only while
something animates, wrapped at one hour (seamless for any multiple of 1/3600 Hz, such as every
integer BPM). Time stands still while nothing animates and while the window is hidden. A frame
with an animated type on screen and nothing else changed runs no `App.draw` and no hashing,
writes 16 bytes of time, and repaints only the animated tiles. In bench mode, time is exactly
1/60 s per presented frame, so dumps compare across runs.

Measured at 2856 by 2514 with the live screen's `pulse`: every frame cached, none drew, none
hashed; recording takes 1.9 microseconds on the RTX 3060 and 3.4 on the UHD 770, and the GPU
frame is 0.13 ms and 1.4 ms (the cached `typing` frame is 0.13 and 1.5). Dumps with the cache
on and off are identical on both GPUs.

## Draw Types, Layers, and Batches

A draw type is an `extern struct` plus a WGSL `fn pixel(px: Pixel) -> vec4<f32>`. The app
lists its types and pool capacities in `config.draw`; the library provides `draw.Box` (fill,
border, radius, hover, down), `draw.Arc` (open ring), `draw.Glyph` (glyph-atlas text written by
`text.place`), and
`draw.Image` (an `rgba8` texture), and `draw.Path` (a stroked polyline, see Paths), and an app
adds its own (the rack's `Led`).

- **Instance convention.** The first `vec4` is `rect` (x, y, width, height in logical
  pixels), the second is `clip` (exclusive-max x0, y0, x1, y1), and up to six parameter groups
  follow. Every field is `f32`, `[2]f32` (at an 8-byte boundary), or `[4]f32` (at a 16-byte
  one), and the size is any multiple of 4, so no hand padding: each full 16 bytes is one
  `float32x4` attribute at locations 1 to 8, and a last partial group is `float32`,
  `float32x2`, or `float32x3` (the rack's `Led` is 52 bytes). `app.check` fails the build
  naming the type and field otherwise (`zig build test-contract` locks one case).
- **WGSL assembly.** `draw/registry.zig` concatenates `draw/prelude.wgsl` (the `Frame`
  uniform, a shared `vs_main`, an `fs_main` that applies the clip mask, and `coverage`,
  `stroke`, `sdf_box`, `sdf_circle`, `sdf_segment`, `sdf_arc`), a `Theme` struct generated from
  `theme.Theme`, the per-type `Instance`, `Varyings`, and `Pixel` structs, and the type's
  `pixel`. Derivatives and `textureSample` must stay in uniform control flow, so `pixel`
  must not call them inside branches on instance data; the prelude guide explains.
- **Vertex.** A type's quad is its `rect` unless it declares `pub const vertex`, a WGSL
  `fn vertex(px: Pixel, unit: vec2<f32>) -> vec2<f32>` returning each corner's position
  relative to `rect.xy`. `local` in `pixel` keeps its meaning, the quad must cover every
  fragment with coverage, and `rect` stays the bounds for clips, shifts, and hit areas
  (`draw/registry.zig`, section 2a). `draw.Path` uses it.
- **Points.** A type that declares `pub const reads_points = true` reads the context's point
  pool as `points: array<vec2<f32>>` at `@group(0) @binding(1)` (read-only storage, vertex
  and fragment stages). The renderer creates that buffer and binds it with the frame uniform,
  once per pass;
  a registry without such a type has no point buffer.
- **Animated.** A type that declares `pub const animated = true` may read the frame's time
  (see Animated Types).
- **Waveforms.** `draw.wave.append(cx, rect, clip, columns, style)` writes one `(min, max)`
  point per column (two with an RMS band) and one `draw.Waveform` quad, whose fragment looks
  up its own column: O(columns) upload, no loop, no texture. `wave.Pyramid(samples_max)`
  builds min, max, and sum-of-squares levels from 64-sample blocks so any zoom fills its
  columns in O(columns). Choose a column count that divides the device width.
- **Offscreen targets.** `textures.create_target(.single | .feedback)` reserves a target, and
  `cx.draw.offscreen(layer, target, rect)` sends that layer's instances, this frame, into
  the target's own pass, recorded before the main pass in layer order, at the rect's device
  pixels. `draw.fx.composite` (opacity, cover, bias) and `draw.fx.blur` (separable Gaussian,
  up to 16 taps a side) sample targets with the `premultiplied` blend; `cover = 0` adds
  light. A single target re-renders only when its layer's content key changes and keeps its
  pixels otherwise; a feedback target renders every frame it is bound and, on its own layer,
  reads its last frame. A rendered target's revision dirties the tiles of everything that
  samples it. At most four targets; `Blend.alpha` writes premultiplied alpha, so a target
  holds correct coverage.
- **Rings.** `draw.TextureRing(format, width, height)` is a ring texture's CPU mirror:
  `push` writes a column at `head`, `flush` (once per draw) queues the pending columns as one
  strided write (two when they wrap). `draw.Ring(format, Color)` shows it oldest-first with
  `textureLoad`, interpolating rows by hand, and calls the app's `Color.wgsl`
  `fn ring_color(value, px)`.
- **Pools and layers.** `cx.append(T, texture, instance)` writes to `T`'s pool on the current
  layer (`cx.draw.layer(.overlay)` returns the previous layer for restoring; `.popup` and
  `.tooltip` are the top two, used by popups). A full pool or
  batch list refuses the instance and counts it in `cx.draw.overflow_count`; in builds with
  runtime safety both hosts log refused instances, areas, and glyphs once per change
  (`cx.overflow_report()`).
- **Sticky batches.** At frame end each pool is stably sorted by (layer, texture) with a
  counting sort, skipped when appends were already in order, and each (layer, type, texture)
  run is one draw call. Layers draw in order; within a layer, batches draw in order of first
  appearance. Box, glyph, box, glyph in one layer is two draw calls, not four.
- **Draw order inside a layer.** Because a batch draws where its first instance appeared, a
  Box appended after any Glyph on the same layer draws under every glyph: a panel face drawn
  after a title hides nothing, but the title's batch already opened, so labels placed on that
  face draw under it. Append faces before any text on the layer, or put what must cover on a
  higher layer. The sort key is 16 bits (`layer * 64 + texture`), so up to 64 textures and the
  8 layers no longer bound each other.
- **Uploads.** Each pool uploads up to four ranges of changed records (`draw.dirty_ranges`),
  bridging gaps of up to 8 unchanged records, so changes at both ends of a pool write two short
  ranges: a key typed into the live stress text uploads 6.9 KB instead of 72 KB.
- **Textures.** `textures.create(format, width, height)` returns a `TextureId` and
  `textures.write(id, region, bytes)` queues pixels (`write_strided` takes a row stride, for a
  sub-rectangle of a larger image); both are recorded into the next stream, each texture with
  its own bind group. The glyph atlas is texture 0. Formats are `r8`, `rgba8`, `r16float`,
  `rg16float` (bytes are `f16` bit patterns), `r32float`, and `rg32float`; all sample as
  `texture_2d<f32>`. The 32-bit formats are not filterable in core WebGPU, so they bind
  through a second layout with a non-filtering sampler and must be sampled `nearest`.
- **Sampling.** `textures.create_sampled(format, width, height, .{ .filter, .address_u,
  .address_v })` picks the filter (`nearest`, `linear`) and per-axis address mode (`clamp`,
  `repeat`); `create` is linear and clamped. One sampler per mode (8 at most) is created the
  first time a texture uses it. Textured types also get `load_texture(texel)` (a
  `textureLoad`, no derivatives) and `texture_size()` beside `sample_texture(uv)`.
- **Blending.** A type may declare `pub const blend: draw.Blend`: `.alpha` (default,
  source-over), `.additive` (`dst + rgb * a`), or `.multiply` (`dst * mix(1, rgb, a)`, the mix
  generated as the type's `blend_out`). Clipped-out pixels leave the target unchanged in every
  mode, and the pixel cache stays exact because a cached rect replays every batch in order.
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
Colors live in instances and in the theme's lighten, darken, background, and arc slots, never
in WGSL literals.

Memory: each pool holds `cap` records plus a renderer shadow of the same size, and one scratch
buffer of the largest pool backs the counting sort. The context also holds the glyph cache
(about 1.25 MiB: the 1 MiB atlas mirror, the table, and raster scratch). The hosts keep the
app, the context, and the renderer in static memory (BSS on wasm), so the linker sizes the
wasm initial memory to cover them and a large app (the editor is about 300 KiB) never grows
the native stack. A registry with `draw.Path` adds `point_cap` 8-byte points and a
shadow of the same size. The UI context around the draw context adds `area_cap` 56-byte hit
areas, 32 turtle entries, and, in safe builds only, a duplicate-id table of 12 bytes per slot
(`2 * area_cap` rounded up to a power of two).

## Paths

`draw.path` strokes polylines with round caps through the `Path` draw type
(`src/draw/path.zig`):

```zig
const stroke: draw.path.Stroke = .{ .color = color, .width = 4, .hover = 0 };
const placed = draw.path.cubic(cx.drawing(), .{ p0, p1, p2, p3 }, stroke, clip);  // ?Placed
_ = draw.path.polyline(cx.drawing(), &points, stroke, clip);
_ = draw.path.plot(cx.drawing(), &samples, rect, .{ lo, hi }, stroke, clip);
_ = draw.path.polyline_at(cx.drawing(), &points, origin, stroke, clip);  // bool, no area
if (placed) |p| cx.path_area(id, p, stroke.width, flags);             // hit within width / 2 + 3
```

- **Flattening.** A cubic gets `clamp(ceil(((chord + control polygon) / 2) / 6), 4, 64)`
  segments.
- **Chunks.** Each `Path` instance (80 bytes) covers a chunk of at most 16 points of the point
  pool, and its fragment takes the minimum distance over the chunk's segments, so joints
  inside a chunk blend once. Chunks share their end point by index (no point is stored
  twice), hold at least four segments, and stop growing past `chunk_area_max` square pixels
  of padded bounds, which bounds the overdraw of diagonals. At a seam each chunk also
  measures its neighbour's segment, and a fragment belongs to the chunk with the nearest
  segment, so a translucent stroke shows no dots at seams. Parts of one path closer than the
  width, more than a segment apart across a seam, still blend twice; the path tests measure
  it.
- **Oriented quads.** A chunk's `rect` is its axis-aligned bounds, but it rasterizes a
  rectangle along its chord (first to last point), padded by half the width plus one logical
  pixel (`Path.vertex`). On the live screen's stress text the curves' boxes covered 0.98
  windows for 0.09 windows of stroke; with the quads the integrated GPU's pass fell from about
  6.5 to 2.8 ms (fastest of three interleaved runs, 2856 by 2514 window) and the RTX 3060's
  from 641 to 371 microseconds. Test "every chunk's oriented quad contains its stroke" locks
  the cover.
- **Coordinates.** Points are stored relative to the path's origin, and each chunk carries
  `anchor = origin - rect.xy`, so a container's alignment shift moves strokes with their
  rects. The origin is the bounds' top-left, or the caller's with `polyline_at`, which keeps
  every unmoved point's stored value when the bounds change (an automation lane).
- **Appends are atomic.** A path whose chunks or points do not fit is refused whole and counted
  in `overflow_count`.

The CPU twins (`distance_to_polyline`, `oriented_quad`, `chunk_alpha`, `draw.sdf_segment`)
check the shader's math, the chunk rects and quads, and the seam blending without a GPU.

## Code Editor

`patchwork.editor.Editor` is a widget like `TextField` over a 64 KiB text
(`src/editor.zig` and `src/editor/*.zig`):

```zig
app.editor.init(ui.id("editor", 0), editor.default_style);   // out-pointer: about 300 KiB
_ = app.editor.load(patchwork_source);                       // sanitized; history cleared
switch (app.editor.handle(cx, event)) { .changed, .refused, .none => {} }
app.editor.draw(cx, ui.sized(.fill, .fill));                 // or the row iterator below
```

- **Buffer.** One contiguous `[65536]u8` edited with `@memmove` (about 0.8 microseconds for
  64 KiB even in Debug), a `[4096]u32` line index shifted on edit, and a cached tokenizer
  start state per line, recomputed from the edited line until one matches.
  `replace(range, utf8)` is the only edit; an edit past 64 KiB or 4,096 lines is refused
  whole and the action is `refused`.
- **Undo.** 256 entries over a linear 128 KiB byte arena, oldest dropped first, the newest
  always undoable. Typing coalesces per word, Backspace runs coalesce, everything else is one
  entry, and `gesture_begin`/`gesture_end` merge any edits into one. Undo and redo restore
  the selection; `history_mark()` drives a dirty marker that undo can clear.
- **Grid.** 15 px Noto Sans Mono: a 9 px column and a 21 px line, one column per codepoint.
  Tabs never reach the text (Tab inserts spaces to the next multiple of four, pastes expand
  them, `ui.edit.sanitize_text`). `text/mono.zig` builds a per-frame table of the ASCII
  glyph entries (which also pre-warms them) and appends glyphs directly, with the same
  instances `text.place` writes.
- **Keys.** Arrows, words with Ctrl, goal column on Up and Down, Home, End, Page Up and
  Down, Ctrl+Home and End, Shift selection, Backspace and Delete (words with Ctrl), Enter
  with the line's indent, Tab and Shift+Tab (several selected lines indent and outdent as
  one entry), Ctrl+A, C, X, V, Z, Shift+Z, and Y. Clicks 1, 2, and 3 place the caret, select
  a word, and select a line; a drag extends without scrolling past an edge.
- **Scrolling.** Vertical in a step 14 view (thumb, wheel `dy`); horizontal is the editor's
  own `scroll_x` (wheel `dx`, or `dy` with Shift), clamped by the longest line. Every edit
  and caret move keeps the caret visible.
- **Bounds.** At most `editor.lines_max` (128, which fills a 2,688 px viewport) lines of
  `editor.columns_max` (200) columns draw, so a draw appends at most `editor.glyph_max`
  (26,112) glyphs; an app asserts that against its glyph pool.
- **Decorations and rows.** The app sets up to 2,048 `Decoration{start, end, kind}` (`box`,
  `strike` over the text on layer 1, `error`) and 32 `InlineRow{after_line, height}`, and
  rebuilds them on a new `revision()`. Rows are filled through
  `draw_begin` / `while (next_row(cx)) |slot|` / `draw_end`; `rect_of(byte)` is the
  character's unclamped logical rect for anchors and `viewport()` the box to clamp against.

## Text

`patchwork.text` draws three embedded faces: `.sans` (Noto Sans Regular), `.sans_bold` (Noto
Sans Bold), and `.mono` (Noto Sans Mono Regular), all SIL OFL 1.1 (`src/text/fonts/OFL.txt`).
Both targets `@embedFile` them, so the browser fetches no font files and a project using
`addApp` gets them with the library. The TrueType tables are parsed at compile time.

- **Subset at build time.** The build runs `tools/subset.zig` (`src/text/subset.zig`) once
  per range set and embeds the results through a generated `patchwork_fonts` module. By
  default the faces keep Basic Latin, Latin-1, Latin Extended-A, the punctuation and symbols
  UI text uses (dashes, quotes, the ellipsis, arrows, €, ™, ≤, ≥), and U+FFFD: about 365
  glyphs and 23 KB a face, without hinting instructions, which the rasterizer never ran.
  Native and wasm embed the same bytes, so they draw the same. A ReleaseSmall `live.wasm`
  went from 2.04 MB to 254 KB. A codepoint outside the ranges draws `.notdef`;
  `AppOptions.font_ranges` widens them, and `null` embeds the full faces.

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
- **Monospace grid.** `text.Mono` (`src/text/mono.zig`) is the editor's path: `prepare`
  looks up the 94 inked ASCII glyphs once per frame, `emit` appends a glyph at a column with
  no measuring, and both share `place`'s snapping, so their records are byte for byte equal.

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
- `poll` descriptor set: six fixed slots, the Wayland display socket, `timer_fd`, the key
  repeat timerfd, the clipboard's send and receive pipes, and the audio wake's `eventfd`; an
  inactive slot is -1, which `poll` ignores. The repeat timer is armed only while a repeating key is held, and the pipes
  exist only during a transfer, so a focused idle text field sleeps.
  When `App.config.timer_period_ms == 0`, `timer_fd` is -1 (`no_timer_fd`), which `poll`
  ignores. The thread sleeps indefinitely while idle.
- When `timer_period_ms != 0`, the timer is created disarmed and `sync_timer` arms or
  disarms it before every sleep to match `cx.timer_on`; while armed it wakes the thread via
  `drain_timer` calling `App.timer(now_ms)`.
- An app with an `Audio` source gets an engine (`src/host/audio_thread.zig`): a thread spawned
  at the first `set_audio(true)`, paced by `clock_nanosleep`, parked on a futex while stopped,
  and joined at exit. Every wake drains the queue through `App.audio` (`sync_audio`) before
  the frame is scheduled, and the exit log line reports blocks, drops, wakes, and late posts.
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
- Input: `wl_seat` is bound at `min(advertised, 8)`. All three buttons and both wheel axes
  are forwarded. Keys go through libxkbcommon (the compositor's keymap, modifiers, and the
  locale's compose table for dead keys), and repeat follows `wl_keyboard.repeat_info` (25 Hz
  after 600 ms when the seat is too old to send it). Keyboard enter and leave are
  `window_focus`. The cursor is set with `wp_cursor_shape_v1` when the shape changes or the
  pointer enters; without that protocol the host logs once and leaves the cursor alone.
- Clipboard: `wl_data_device_manager` (version 3). A copy offers `text/plain;charset=utf-8`,
  `UTF8_STRING`, and `text/plain`; transfers run through non-blocking pipes in the poll set,
  a paste reads at most 64 KiB, and `SIGPIPE` is ignored. A stalled peer costs no wakes and
  is closed when the next copy or paste replaces it.
- GPU setup: after `gpu.create` makes the device, the host submits the renderer's setup
  stream. The device's uncaptured-error callback is installed, so a validation error fails the
  frame with the op index, the op name (with the draw type's label for a shader), and the
  driver message instead of aborting.

### Browser (WebAssembly + WebGPU)

In the browser host (`src/host/web_exports.zig` and `web/shell.js`):
- `start()` initializes static Wasm state (the draw context and renderer live in BSS) without
  heap allocation, then initializes the app before recording the setup stream.
- `web/shell.js` calls `sync_timer()` after every Wasm call (where it syncs the cursor), in
  the interval callback, and after `start`: it keeps one `setInterval` of
  `wasm.timer_period_ms()` calling `wasm.timer(now_ms)` exactly while `wasm.timer_on()` is 1.
  If `timer` returns 1, `shell.js` schedules a single `requestAnimationFrame`.
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
- Keyboard and clipboard: the canvas is focusable (`tabindex="0"`); `keydown` and `keyup`
  pass `event.key` as UTF-8 through the Wasm input buffer, and Zig names the key, so
  `shell.js` maps no keys. `preventDefault` runs only when Zig reports the key consumed
  (focus or Tab), never for Ctrl or Meta with C, X, or V, so the page's `copy`, `cut`, and
  `paste` events fire and use `clipboardData` synchronously. Canvas focus and blur are
  `window_focus`, the context menu is suppressed, all buttons are forwarded, and after each
  call `shell.js` sets `canvas.style.cursor` from `cursor()` and the CSS names Wasm exports.
  IME composition is not supported.
- `present_frame()` records a frame into a static `CommandBuffer` and calls `submit_js` once.
  JavaScript decodes the stream and its spans in place, with no intermediate copies, and
  asserts that `pass_begin` carries the canvas backing size.
- `?bench=1` times every render pass with `timestamp-query` when the adapter has it (see Bench
  Mode).
- Audio: `sync_audio()` runs wherever `sync_timer()` runs. The first `audio_on()` creates an
  `AudioContext` at 48 kHz inside the input handler, loads `worklet.js`, and passes it the
  wasm's bytes; later changes resume or suspend the context. Each message of 4 blocks is
  copied into `audio_inbox_ptr()` and pushed with `audio_push`, which schedules a frame;
  `tick` drains the queue before it animates and presents.
