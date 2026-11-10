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
| `config` | `Config` | `title`, `timer_period_ms`, `timer_armed`, `draw` (types and capacities), `batch_cap`, `batch_order` (see Draw order), `area_cap`, `point_cap`, `theme` (see Theme). |
| `init` | `fn (*App, *draw.Textures) void` | Called once before any other call; may create textures. |
| `event` | `fn (*App, *Context(App), Event) void` | Routes pointer, wheel, key, paste, window focus, file drop, and `frame` events to the app's widgets. |
| `timer` | `fn (*App, *Context(App), u64) void` | Called on host timer expiration while the timer runs. |
| `draw` | `fn (*App, *Context(App)) void` | Lays out and appends every instance, recording hit areas. |
| `scenarios` (optional) | `[]const bench.Scenario` | Scripted runs for `--bench` (see Bench Mode). |
| `args` (optional, native) | `fn (*App, []const [:0]const u8) void` | Receives the arguments the host does not know, once, after `init` (see Use Patchwork From Another Project). |
| `wake`, `pending`, `drain` (optional, together) | `fn (*App) *patchwork.Wake`, `fn (*const App) u32`, `fn (*App, *Context(App)) void` | A producer on another thread: the app's own wake, what it has waiting, and the one call on the UI thread each wake (see Data From Another Thread). |
| `produce` (with them) | `fn (*App, u32) void` | Steps the producer by frames of a 48 kHz clock where no thread runs it: regress, the bench, a browser replay. |

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

**Audio.** Patchwork has no audio engine since step 56: an app plays sound through a peer
library such as Thrum and brings its data back through a producer (below). `examples/sound` is
the worked example.

**A producer.** An app whose data comes from another thread declares `wake`, `pending`, and
`drain` (see Data From Another Thread below); the UI sleeps until the producer notifies.

The contract is validated at compile time by `patchwork.app.check(App)`. Missing or
mistyped declarations, a draw type that breaks the instance convention (the message names
the type), a zero capacity, a `batch_cap` whose worst frame would not fit one command
buffer, an `area_cap` outside 1 to 65536, a `point_cap` outside 1 to 65536, and a
`config.theme` color component outside `[0, 1]` produce a clear `@compileError` naming the
exact problem (`App.config.theme.colors.panel: a component is outside [0, 1]`). `point_cap` (default 65,536) sizes the path
point pool, which exists only when a registered type reads points (`draw.Path`).

Widgets (`patchwork.widgets`) are plain structs the app owns: `Panel`, `Label`, `Paragraph`, `Button`,
`Toggle`, `Checkbox`, `Slider`, `Knob`, `Meter`, `TextField`, the popups (`Menu`, `ContextMenu`,
`Dropdown`, `Tooltip`), the containers and value boxes (`Tabs`, `Segmented`, `Splitter`,
`ListBox`, `NumberBox`), trees and tables (`TreeView`, `Disclosure`, `ColumnHeader`), and
window chrome (`MenuBar`, `WindowButtons`, `window_drag`, `window_edges`); the code editor
(`patchwork.editor.Editor`, see Code Editor below) follows the same contract. Each draws with `draw(cx, walk)` and,
when interactive, answers `handle(cx, event)` with an action such as `Knob.Action.changed`.
Events resolve once per event against the areas of the last frame, so `handle` is O(1) per
widget; the app routes every event to every widget it owns.

### Events

`patchwork.input.Event` is one of:

| Event | Payload |
|---|---|
| `pointer_move` | `Point{x, y}` in logical pixels |
| `pointer_down`, `pointer_up` | `Button{x, y, time_ms, button: .left/.right/.middle, mods, serial}` |
| `pointer_leave` | none |
| `wheel` | `Wheel{x, y, dx, dy}` |
| `key_down`, `key_up` | `KeyPress{key, mods, repeat, len, text: [4]u8}`: the typed text rides on `key_down` |
| `paste` | `[]const u8`, valid only while it is dispatched |
| `window_focus` | `bool`: false releases held keys and modifiers |
| `drop_over` | `Point{x, y}`: a drag carrying files is over the window |
| `drop_leave` | none: that drag left, or ended without dropping here |
| `drop` | `*const Drop{x, y, count, skipped, files}`, valid only while it is dispatched |
| `file` | `*const Chunk{file, offset, bytes, end}`: bytes of an accepted file, valid only while it is dispatched |
| `frame` | the animator step in milliseconds |
| `close_requested` | none: the window manager asks to close; the app closes unless it calls `cx.keep_open()` |
| `window_state` | `WindowState{maximized, fullscreen, activated, tiled sides, decorations, capabilities}` |

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
│   ├── imports.zig             # The rules for an app's or a tool's import lists (build.zig imports it)
│   ├── app.zig                 # App contract definitions and comptime check
│   ├── ui.zig                  # UI namespace: dispatch, animate, draw_frame, re-exports
│   ├── ui/turtle.zig           # Pure layout math: Walk, Size, Layout, Flow, fit, alignment
│   ├── ui/areas.zig            # Id, Area, the hit resolve scan, duplicate-id stamps
│   ├── ui/cx.zig               # UI Context: draw context, turtle stack, areas, hover, capture
│   ├── ui/view.zig             # Scrolling views (ViewState, scrollbar) and the virtual List
│   ├── ui/canvas.zig           # Pan/zoom canvases: CanvasState, the zoom ladder, wheel and drag
│   ├── ui/gestures.zig         # Per-target recognizer: tap, drag, long-press, pinch, two-finger
│   ├── ui/edit.zig             # Editing core: bounded UTF-8 field, caret, words, sanitizing
│   ├── ui/popup.zig            # Popup placement: place (side, flip, clamp, cut), Anchor
│   ├── widgets.zig             # Widgets namespace: re-exports every widget and constant
│   ├── widgets/kit.zig         # The widget kit: append, face, arc, label, step, aim, weight,
│   │                           #   clicked, Interaction, Paint, the hover and press constants,
│   │                           #   surface, lit, backdrop, glass, glass_look, glass_face
│   ├── widgets/skin.zig        # Skins: the look structs, Shape, skins.check, skins.Default
│   ├── widgets/label.zig       # One file per widget, with its constants, geometry, and tests:
│   ├── widgets/panel.zig       #   Label, Panel, Button, Slider, Knob (and the shared ring and
│   ├── widgets/button.zig      #   label-column geometry, accents), Meter, Toggle, TextField
│   ├── widgets/slider.zig
│   ├── widgets/knob.zig
│   ├── widgets/meter.zig
│   ├── widgets/toggle.zig
│   ├── widgets/checkbox.zig    # Checkbox: a box, a check mark or a mixed bar, and its label
│   ├── widgets/text_field.zig  # TextField: hint, secret (bullets), and a leading icon too
│   ├── widgets/paragraph.zig   # Paragraph: text wrapped to its width; a fit height for that width
│   ├── widgets/menu.zig        # Menu and ContextMenu: a list in a popup, keys and pointer
│   ├── widgets/dropdown.zig    # Dropdown: a face showing the selection and its Menu
│   ├── widgets/tooltip.zig     # Tooltip: one line after a hover dwell, on the tooltip layer
│   ├── widgets/tabs.zig        # Tabs: a bar over a page; close, reorder, drag out; Segmented
│   ├── widgets/splitter.zig    # Splitter: two panes and a draggable divider, begin/next/end
│   ├── widgets/dock.zig        # Dock: a tree of splits and tab sets; drop zones, save and load
│   ├── widgets/list_box.zig    # ListBox: a virtual list with selection, keys, scroll-into-view
│   ├── widgets/number_box.zig  # NumberBox: drag, wheel, or type a value with a unit
│   ├── widgets/tree_view.zig   # TreeView: pre-order nodes flattened into a ListBox, chevrons, keys
│   ├── widgets/disclosure.zig  # Disclosure: a header with a chevron over a section drawn while open
│   ├── widgets/column_header.zig # ColumnHeader: resizable, sortable columns and a row's spans
│   ├── widgets/window_chrome.zig # WindowButtons, the drag area, and the resize edges
│   ├── widgets/menu_bar.zig    # MenuBar: menus side by side; hover and Left / Right switch them
│   ├── widgets/fixture.zig     # The widget tests' static context and drivers
│   ├── editor.zig              # Code editor namespace: EditorOf, Editor, Style, Decoration
│   ├── editor/language.zig     # The language contract (State, Class, palette, faces, scales, next)
│   ├── editor/buffer.zig       # 64 KiB contiguous text, line index, start states, undo arena
│   ├── editor/tokenizer.zig    # The patch language (the default): per-line states, seven classes
│   ├── editor/literal.zig      # Number literals a widget writes back digit for digit; range shifts
│   ├── editor/editor.zig       # The editor widget: grid, view, keys, selection, rows
│   ├── draw.zig                # Drawing namespace: projection, unit quad, dirty ranges, re-exports
│   ├── draw/registry.zig       # DrawType, instance convention check, WGSL assembly, layouts
│   ├── draw/prelude.wgsl       # Shared vs_main, fs_main, coverage, clip mask, distance fields
│   ├── draw/types.zig          # Library draw types (Box, Arc, Surface, Glyph, Image, Path), twins
│   ├── draw/pools.zig          # Context: per-type pools, point pool, layers, sort, batches
│   ├── draw/path.zig           # Stroked paths: flattening, chunking, twins, appenders
│   ├── draw/fill.zig           # Filled shapes: Builder, bands, exact-area coverage, twins
│   ├── draw/backdrop.zig       # Backdrops: the blur chain's levels, passes, reach; Glass; twins
│   ├── draw/textures.zig       # Textures: queued creates and writes, TextureId, write revisions
│   ├── draw/tiles.zig          # Pixel cache tiles: hashes, dirty bits, scissor rects, record keys
│   ├── draw/renderer.zig       # Records setup and frame command streams; frame kinds, kept target
│   ├── text.zig                # Text namespace: faces, Style, measure, place, place_runs, icon
│   ├── text/ttf.zig            # Comptime TrueType reader: cmap 12/4, hmtx, glyf, composites
│   ├── text/subset.zig         # Build-time subsetter and app face check: glyph closure, no hinting
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
│   ├── wake.zig                # Wake: a producer on any thread wakes the UI's poll loop
│   ├── drop.zig                # File drops: the file list, the URI list parser, the transfer
│   ├── serve.zig               # Built-in static HTTP server for browser testing
│   └── native_tests.zig        # Test root of tests that call system libraries, files, or threads
├── src/host/                   # Platform host implementations generic over App
│   ├── native_main.zig         # Native entry point: parses options, runs linux_window.run(App)
│   ├── web_main.zig            # Wasm entry point: calls web_exports.export_app(app.App)
│   ├── linux_window.zig        # Linux Wayland event loop, timerfd, producer wake, and Host(App)
│   ├── web_exports.zig         # Wasm exports and zero-copy FFI bridge via @export
│   ├── gpu_wgpu.zig            # Native replayer: id tables, execute, swapchain, headless target
│   ├── offscreen.zig           # Offscreen(App): frames with no window, at any size and time
│   ├── headless.zig            # `--regress` and `--render`: scenarios on Offscreen, goldens
│   ├── wl_seat.zig             # Wayland seat, pointer, and keyboard bindings (version 8)
│   ├── xkb.zig                 # libxkbcommon: keymap, modifiers, text, compose, repeat
│   ├── wp_cursor_shape.zig     # wp_cursor_shape_v1 bindings and the cursor shape map
│   ├── wl_data_device.zig      # Clipboard and drag-and-drop bindings (wl_data_device_manager 3)
│   ├── clipboard.zig           # Clipboard state machine: selection, send and receive pipes
│   ├── dnd.zig                 # Native file drops: the drag offer, its URI list, file reads
│   ├── dnd_test.zig            # Its tests: real files, a folder, a FIFO (native test root only)
│   ├── wl_callback.zig         # Wayland frame completion callback
│   ├── wp_presentation.zig     # Wayland presentation-time feedback listener
│   ├── wp_fractional_scale.zig # wp_fractional_scale_v1 and wp_viewporter bindings
│   └── xdg_shell.zig           # XDG shell surface and toplevel protocol
├── examples/                   # Example applications
│   ├── sound/                  # A package of its own: the examples that play Thrum (step 55)
│   │   ├── build.zig           # Both apps through addApp; Patchwork and Thrum as path deps
│   │   ├── rack.zig            # Rack App: the modular synthesizer rack
│   │   ├── rack/led.zig        # The rack's own draw type: a glowing LED
│   │   ├── rack/badge.zig      # Procedural 32 by 32 RGBA badge texture
│   │   ├── audio.zig           # Audio App: test tone meters, triggered scope, XY trace
│   │   ├── tone.zig            # The glue: Thrum's test tone on a device, offline, or a page
│   │   ├── tone.js             # Their web module: Thrum's worklet from the app's own wasm
│   │   └── test/golden/        # The two apps' goldens
│   ├── column/                 # Scrolling view regression app
│   │   └── app.zig             # Column App (config.timer_period_ms = 0)
│   ├── live/                   # Live-coding screen
│   │   ├── app.zig             # Live App: header, editor, knob column, curves, lanes, transport
│   │   ├── bindings.zig        # Binding parser: k() calls, shape() calls, bpm
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
│   ├── wake/                   # A producer on another thread into the UI (step 54)
│   │   ├── app.zig             # Wake App: a ring, a thread or produce or a page interval, a sparkline
│   │   └── app.js              # Its web module: the page's producer on a 5 ms interval
│   ├── canvas/                 # Pan and zoom
│   │   └── app.zig             # Canvas App: a 1,000-module grid with cables, select and drag
│   ├── gallery/                # Every library widget on tabbed pages (phases 6 and 7)
│   │   ├── app.zig             # Gallery App: built only from widgets.kit and layout defaults
│   │   ├── hardware.zig        # A hardware skin: the Dial and Bevel draw types, an Led, Skin
│   │   ├── icons.zig           # Named Lucide codepoints and the icon face's ranges
│   │   ├── files.zig           # The files page: a drop zone, the dropped files, a waveform
│   │   ├── wav.zig             # A streaming 16-bit PCM WAV decoder fed chunk by chunk
│   │   ├── surfaces.zig        # The surfaces page: gradient cards, rims, and shadows
│   │   ├── glass.zig           # The glass page: cards under glass, materials, a lens slider
│   │   ├── code.zig            # The code page: the editor in C and XML side by side
│   │   ├── tabs.zig            # The tabs page: two bars whose tabs close, reorder, and move
│   │   ├── c.zig               # A C language for the editor (a recipe to copy)
│   │   ├── xml.zig             # An XML language for the editor (a recipe to copy)
│   │   ├── sample.c            # The C page's sample
│   │   ├── layout.xml          # The XML page's sample, every XML state across a line
│   │   └── fonts/              # lucide.ttf (lucide-static 1.55.0, ISC, LICENSE)
│   ├── workspace/              # A docking workspace (step 46)
│   │   ├── app.zig             # Workspace App: files, editor, log, appearance in a Dock
│   │   ├── c.zig               # The C language recipe, copied from the gallery
│   │   └── sample.c            # The editor's sample
│   └── session/                # A live-coding music screen rebuilt from photos (step 47)
│       ├── app.zig             # Session App: the document's rows, mixer, sidebar, card
│       ├── patch.zig           # The patch as a language: faces, headings, and channel colours
│       ├── bindings.zig        # The mix's numbers: parsed from the text, written back to it
│       ├── sections.zig        # Moving a section: a pure function of the text
│       ├── look.zig            # Palette, serif styles, Ring/Bipolar knob and Pill skins
│       ├── fader.zig           # Fader: an upright level with a stereo meter in its track
│       ├── keys.zig            # Keyboard: a piano played by pointer and tracker keys
│       ├── plots.zig           # Transfer curve, envelope, response, bars, spectrum fills
│       ├── signal.zig          # Four made-up channels as pure functions of time
│       ├── faces.zig           # The serif faces' ranges (build.zig imports it)
│       └── fonts/              # Noto Serif Regular, Italic, Bold, pre-subset (OFL)
├── tools/
│   ├── compare.zig             # `zig build compare`: how two frames differ; diff and crop PNGs
│   ├── browser_check.py        # A scenario replayed in Chromium against its headless frame
│   └── subset.zig              # The build's font subsetter (runs text/subset.zig on a face)
├── web/                        # Browser harness
│   ├── index.html              # WebGPU canvas host page
│   ├── shell.js                # Generic command interpreter, Wasm bridge, and input handler
│   └── app.js                  # The empty web module served when an app brings none
└── test/                       # Regression tests
    ├── golden/<adapter>/<app>.txt # Regress hashes per adapter and driver (`zig build regress`)
    ├── contract_missing_draw.zig # Test verifying that missing draw fails compilation
    ├── contract_ragged_type.zig  # Test verifying that a 36-byte draw type fails compilation
    ├── contract_frozen_time.zig  # Test verifying that reading time without `animated` fails
    ├── contract_producer_without_drain.zig # A producer without `drain` fails
    ├── contract_producer_produce_only.zig # `produce` without a producer fails
    ├── contract_theme_range.zig  # Test verifying that a theme color of 1.5 fails, naming it
    ├── contract_skin_missing.zig # Test verifying that a skin without `knob` fails, naming it
    ├── contract_overlays_none.zig # Test verifying that `ui.overlays` of a target without
    │                              # any `draw_overlay` fails, naming it
    ├── contract_args_mistyped.zig # Test verifying that an `args` of the wrong type fails
    └── consumer/               # A package outside this build (`zig build test-consumer`)
        ├── build.zig, build.zig.zon # `addApp` and `addTool` through a `.path` dependency
        ├── app.zig             # Imports both peers, declares `args` and a still scenario
        ├── tool.zig            # Its own main over Offscreen: a frame at a time it is given
        ├── song.txt            # The file the app is named on the command line
        ├── test/golden/        # The consumer's own goldens
        └── peers/
            ├── pure/           # No dependencies: one target-less module
            └── linked/         # Links libxkbcommon natively, nothing on wasm
```

## Build Steps

Use the distro `zig` (`/usr/bin/zig` on this machine; Zig 0.17.0). Native builds link
`libwayland-client` and `libxkbcommon` dynamically through pkg-config, so both libraries and
their `.pc` files must be installed (every Wayland desktop ships the libraries); a system
without them refuses to start the executable. The wasm build links nothing.

```bash
# Examples (Gallery, which also owns the plain names)
zig build run             # Build and run the widget gallery natively (Wayland + wgpu-native)
zig build wasm            # Compile the gallery to zig-out/bin/gallery.wasm (wasm32-freestanding)
zig build serve           # Serve the gallery WebGPU application on localhost (prints the address)

# Examples (Rack and Audio, in examples/sound, with Thrum checked out at ../thrum)
cd examples/sound
zig build run             # The synthesizer rack natively; Space plays Thrum's test tone, audible
zig build serve           # The rack in the browser; Space plays the tone in Thrum's worklet
zig build run-audio       # The audio meters, scope, and XY trace natively, audible
zig build serve-audio     # The same in the browser
zig build test            # Both apps' tests and the glue's
zig build regress         # Both apps' scenarios against examples/sound/test/golden

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

# Examples (Wake)
zig build run-wake        # A producer thread into the UI; Space starts and stops it
zig build serve-wake      # The same with the page's own producer (examples/wake/app.js)

# Examples (Pan and Zoom Canvas)
zig build run-canvas      # Build and run the module canvas natively
zig build wasm-canvas     # Compile it to zig-out/bin/canvas.wasm
zig build serve-canvas    # Serve it on localhost (prints the address)

# Examples (Widget Gallery)
zig build run-gallery     # Build and run the widget gallery natively
zig build wasm-gallery    # Compile it to zig-out/bin/gallery.wasm
zig build serve-gallery   # Serve it on localhost (prints the address)

# Examples (Docking Workspace)
zig build run-workspace   # Build and run the docking workspace natively
zig build wasm-workspace  # Compile it to zig-out/bin/workspace.wasm
zig build serve-workspace # Serve it on localhost (prints the address)

# Examples (Live-Coding Session)
zig build run-session     # Build and run the live-coding session natively
zig build wasm-session    # Compile it to zig-out/bin/session.wasm
zig build serve-session   # Serve it on localhost (prints the address)

# Examples (Vector)
zig build run-vector      # Build and run the filled shapes natively
zig build wasm-vector     # Compile it to zig-out/bin/vector.wasm
zig build serve-vector    # Serve it on localhost (prints the address)

# Examples (Touch)
zig build run-touch       # Build and run the multi-touch pads and sliders natively
zig build wasm-touch      # Compile it to zig-out/bin/touch.wasm
zig build serve-touch     # Serve it on localhost (prints the address)

# Validation
zig build test            # Run unit tests across the library and the twelve examples
zig build test-contract   # Verify compile errors for a missing `draw`, a ragged draw type,
                          # a type that reads time without declaring `animated`, an
                          # producer without `drain`, a theme color of 1.5, a
                          # knob skin without `knob`, `ui.overlays` of a target
                          # with no `draw_overlay`, an editor language without
                          # `next`, `draw.covered_glyphs` without a `Box`, too few `faces`
                          # in an editor language, `scales` without `faces`, and an
                          # `args` of the wrong type
zig build check           # Compile every example's shaders and pipelines on a GPU with no
                          # window; fails naming the broken draw type (needs a GPU)
zig build check -- --adapter low   # The same on the integrated GPU
zig build regress -Doptimize=ReleaseFast   # Every example's scenarios headless on both GPUs,
                          # cache on and off, against test/golden (needs a GPU; see Regression)
zig build regress -Doptimize=ReleaseFast -- --bless   # Rewrite the goldens from this run
zig build test-consumer   # test/consumer, a package outside this build: native, wasm, its tests
                          # and regress, its tool, and an argument (needs a GPU)
./zig-out/bin/gallery --render still --out frames     # A scenario's frames as PNGs
python3 -I tools/browser_check.py gallery still   # One scenario in Chromium against headless
python3 -I tools/browser_check.py --root ../app myapp still   # The same, for an app in another tree

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
├── bin/column, live, data,     # native executables, RUNPATH $ORIGIN/../lib
│   wave, fx, wake, canvas,
│   gallery, workspace, ...
├── bin/column.wasm, ...        # from `zig build wasm-column` and the other wasm steps;
│   gallery.wasm                #   `zig build wasm` is the gallery's
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
or `null` for the full faces. `AppOptions.fonts` adds up to five faces of the app's own (see
Fonts).

`addApp` links `libwayland-client` and `libxkbcommon` into the native executable, so a
consumer's build machine needs both (with their pkg-config files) as described under Build
Steps. `steps.install` puts `<name>` in the consumer's `<prefix>/bin` and
`libwgpu_native.so` in `<prefix>/lib`; `steps.run` depends on both and runs the installed executable. Keep the two
directories together when shipping the native build.

`AppSteps` also carries `exe` (the native executable), `library` and `app` (the native
`patchwork` and app modules), and `wgpu_lib` (the directory holding `libwgpu_native.so`), for a
`build.zig` that needs more than the steps. Regress works from a consumer's tree: `steps.regress`
runs from its build root, and its goldens are its own `test/golden/<adapter>/<name>.txt`.

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

### 4. Other Packages

`test/consumer` is a working package with everything below. A peer with no system library, such
as Weft, is one target-less module and goes in `imports`. A peer that links one, such as Thrum,
needs a known target, because `linkSystemLibrary` panics at configure time on a module without one.
It is built once per target and goes in the two per-target lists under one name:

```zig
const weft = b.dependency("weft", .{}).module("weft");
const thrum = b.dependency("thrum", .{ .target = target }).module("thrum");
const wasm = b.resolveTargetQuery(patchwork.wasm_query);
const thrum_wasm = b.dependency("thrum", .{ .target = wasm }).module("thrum");
const steps = patchwork.addApp(b, dep.builder, .{
    .name = "play",
    .root_source_file = b.path("app.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "weft", .module = weft }},
    .native_imports = &.{.{ .name = "thrum", .module = thrum }},
    .wasm_imports = &.{.{ .name = "thrum", .module = thrum_wasm }},
});
```

`patchwork.wasm_query` is the query `addApp` uses, so the peer and the app cannot disagree.

A page of the app's own code goes in `web_module`, an ES module served as `/app.js`, and the files
it fetches in `web_files`, each at its route:

```zig
    .web_module = b.path("web/app.js"),
    .web_files = &.{.{ .route = "/thrum-worklet.js", .path = thrum_dep.path("web/worklet.js") }},
```

The shell imports `/app.js` before it instantiates the wasm. Its `imports(shell)` returns
functions the wasm imports beside Patchwork's own (a clash is an error); its `started(shell)`
runs after `start`. `shell` is `{ wasm, memory, wake, canvas }`, with `wasm` and `memory` set once
the instance exists. This is how a peer's AudioWorklet reaches the page: the wasm calls an import
from a key handler to start it, the import posts the peer's messages, and the worklet's replies
are copied in through the app's exports before `shell.wake()`.

`addApp` panics at configure time, naming the app and the import, on the name `patchwork`, on a
name that appears twice for one target (a name in `imports` and in a per-target list counts), and
on a name in only one per-target list. `@import("thrum")` is in a file that compiles for both
targets, so it must resolve on both: a native-only branch belongs in the peer.

### 5. A Tool

`patchwork.addTool` builds an executable with a `main` of its own over `Offscreen(App)` (see
Rendering Frames), for work with no window:

```zig
const tool = patchwork.addTool(b, .{
    .name = "thumbnail",
    .root_source_file = b.path("tool.zig"),
    .target = target,
    .optimize = optimize,
    .app = steps,
    .imports = &.{.{ .name = "weft", .module = weft }},
});
b.installArtifact(tool);
```

The file imports `patchwork` and `app`, the same modules the app builds with, so the names
`patchwork` and `app` are refused in `imports`. The tool links libc and `libwgpu_native.so` and
finds the library through `$ORIGIN/../lib`; its step depends on `steps.install`, which puts the
library there. It does not link Wayland or xkbcommon, because Zig analyzes only what the tool
references, so it runs with no display. A peer in its graph links what that peer asks for. A tool
that also opens a window is out of scope: that is `addApp`'s executable.

### 6. Command-Line Arguments

An app may declare `pub fn args(app: *App, arguments: []const [:0]const u8) void`, native only:

```bash
./zig-out/bin/play song.txt                   # arguments = song.txt
./zig-out/bin/play --adapter low song.txt     # the host takes low, the app song.txt
./zig-out/bin/play -- --strange-name          # after --, even a dash is the app's
```

- **The split.** The host reads its own options up to a bare argument or `--`, which is dropped.
  The rest are the app's, even a host option. A host option's value is taken with its option, and
  an option the host does not know before the split stays `UnknownArgument`. At most 16 arguments
  in all.
- **Refused.** An app that does not declare `args` and is given any exits with `UnknownArgument`,
  so a mistyped command still fails loudly.
- **Timing.** The window host calls it once, right after `init`, with a slice that may be empty.
  That is before it connects to a display, so `--version` can print and exit there. The strings
  live as long as the process. `--check`, `--bench`, `--regress`, and `--render` do not call it,
  so a golden can never depend on a command line. The browser never calls it either, and the
  function body compiles only natively, so it may use the file system.
- **Opening a file.** `Io` is passed through `main`, which the host owns. `args` needs none of
  it: a single-threaded `Io` is a local with no allocator and nothing to tear down, and blocking
  there is fine, since no frame has run.

```zig
var file_bytes: [1 << 20]u8 = undefined;

pub fn args(app: *App, arguments: []const [:0]const u8) void {
    if (arguments.len == 0) return;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const dir = std.Io.Dir.cwd();
    app.song = dir.readFile(threaded.io(), arguments[0], &file_bytes) catch null;
}
```

A file too long for the buffer comes back cut to it. A large static buffer costs Debug builds
dearly, because static undefined memory is written out per host: a 128 MiB slab in `App` gave a
981 MiB Debug executable against 71 MiB, and 6 MiB either way in ReleaseFast. Use ReleaseFast or
ReleaseSmall for an app with large slabs.

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
  rect), `kit.surface` a `draw.Surface` (see Surfaces), `kit.arc` a `draw.Arc`, `kit.label`
  places text (`kit.paragraph` wrapped), `kit.append` appends any draw type
  and skips it when its pool is full (the context counts it), `kit.step` and `kit.aim` ease
  animators and owe redraws, `kit.weight` and `Paint.look(hover, down)` turn animator values
  into mix weights, `kit.clicked(cx, id, event)` makes a clickable row (true on a release
  inside, a repaint on hover), and `kit.Interaction` (or `kit.respond` on a widget's own
  animators) is the hover and press table every library widget follows. The records come from
  `draw.Box.of(rect, clip, BoxLook)` and `draw.Arc.of(ring, clip, ArcLook)`, whose looks
  default to no border, hover, or press and the full sweep from the theme's start
  (`ArcLook.start`, a fraction of the sweep, moves the arc along the ring: a pan is an arc
  from 0.5); `ui` and `draw` use the constructors directly. One file per widget lives in `src/widgets/`; `widgets.zig`
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
  wake the host. Three optional fields: `hint`, drawn in the field's style at 0.45 alpha while
  it is empty; `secret`, which shows U+2022 per codepoint (the caret, the selection, and
  presses map through it), refuses copy and cut, and sends word moves to the ends; and
  `icon` (`.{ .face, .codepoint }` of an app face), drawn in the field's left 28 px, where the
  text then starts.
- **Checkbox.** `widgets.Checkbox.init(id, label, on)`: a 16 px box, the label to its right,
  and the box and label as the hit area. An inside release or Space while focused flips it
  (`Action.toggled`). `mixed` (the app sets it, for a parent of differing children) draws a
  bar; a flip clears it and turns the box on. The check mark is a `draw.Path`; an app without
  `draw.Path` gets a small square instead (`kit.stroke` returns false).
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
- **Material.** `scheme.material` (`theme.Material`) is what the default skins make panels and
  popups of: `.solid` (the default of both presets, the faces of steps 1 to 39), or glass,
  `.clear`, `.frosted`, or `.tinted`: a backdrop blur (sigma, logical pixels), how far glass
  reads its blurred level (`frost`), a tint toward `colors.panel` (`colors.focus` for tinted),
  `saturation`, a lit `rim`, and `refraction` at the edge. A `Panel` or `Menu` (so a
  `Dropdown`'s list) may set its own `material`. Glass needs `draw.Glass` registered and a
  backdrop under the face (see Backdrops and Glass); without one the skin draws the solid face.

## Make a Skin

A widget's behaviour (its fields, `handle`, and actions) is written once; how it looks and
where it takes presses belong to a skin, a struct of draw functions passed at compile time.
`widgets.Knob` is `widgets.KnobOf(widgets.skins.Default)`; `ButtonOf`, `SliderOf`, `ToggleOf`,
`CheckboxOf`, `MeterOf`, `PanelOf`, `TextFieldOf` (its face and border only), `MenuOf`,
`DropdownOf`, `TabsOf`, `SplitterOf`, `ListBoxOf`, `NumberBoxOf`, `TreeViewOf` (its bands are
the list box's `list_row`, its chevrons `tree_chevron`), `DisclosureOf`, `ColumnHeaderOf`,
`WindowButtonsOf` (`window_button`), and `MenuBarOf` (`menu_title`, and its menus' `menu_face`
and `menu_row`) work the same way. A
`TabsOf` skin may also declare `pub const tab_arrange: widgets.TabArrange = .even` (equal
segments in an inset track); the library's second skin, `skins.Segmented`, does. There
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

- **The value's text.** `knob.draw(cx, walk)` hands the skin hundredths (`"0.50"`);
  `knob.draw_text(cx, walk, text)` hands it the app's own text instead, read during the call
  (`"-27.7db"`, `"100ms"`). Names of knobs and toggles are at most `widgets.name_max` (16)
  bytes; the default skin's label column fits about eight.
- **A toggle's accent.** `Toggle.accent` (null by default) is the thumb's colour when on and
  reaches the skin as `ToggleLook.accent`, so one toggle type serves toggles of many colours.

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
- **Tabs that close and move.** `Tabs.init_keyed(id, labels, keys, selected)` keys each tab
  by an app `u64`, so a tab keeps its id (`id.derive(key)`) wherever it moves. `closable`
  gives every tab a "×" (and a middle press closes); `movable` lets a tab be dragged within
  its bar to reorder, or off it (24 px above or below, or past an end) as a drag between
  widgets (see Drags Between Widgets) whose ghost follows the pointer on the tooltip layer, and
  makes the bar a drop target that shows where a tab would land. The labels and keys stay the
  app's arrays: the bar reports `closed i`, `moved { from, to }`, `dragged_out i` (dropped on
  another target), or `received { payload, index }`, adjusts its own `selected` as if the app
  applied it, and the app updates its arrays with `widgets.move_item`, `remove_item`, or
  `insert_item` and calls `tabs.set(labels, keys)` before the next draw. A bar may be empty.
  A tab dragged from one bar onto another is two actions in one event, the source's
  `dragged_out` and the target's `received`; apply both.
- **Segmented.** `widgets.Segmented` is `TabsOf(skins.Segmented)`: the same behaviour, its
  tabs in equal whole-pixel segments inside a capsule track, the selected one raised. Draw it
  with `bar(cx, walk)`, which draws the bar in the whole box and opens no page.

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

### Trees and Tables

- **TreeView.** `widgets.TreeView(capacity)` over a slice of `widgets.TreeNode` the app owns
  (`parent`, `expanded`, `has_children`) in pre-order: a parent before its children, every
  subtree contiguous. Each draw flattens the visible rows in one linear pass with a fixed stack
  (at most 32 deep, no recursion) into a `ListBox`, so the rows, wheel, and Up, Down, Page Up,
  Page Down, Home, and End are the list box's. `next` hands each row its node, depth, and the
  content rect after the indent and chevron. A chevron press toggles its node; Right expands a
  collapsed parent or steps into an expanded one's first child; Left collapses or steps out to
  the parent; a double click or Enter toggles a parent and activates a leaf. The selection is
  a node, so it survives re-flattening; a collapse that hides it moves it to the ancestor.

  ```zig
  _ = app.tree.begin(cx, ui.sized(.fill, .fill));
  while (app.tree.next(cx)) |row| kit.label(cx, style, names[row.node], row.rect, row.clip, start);
  app.tree.end(cx);
  ```
- **Disclosure.** `if (group.begin(cx, ui.sized(.fill, .fit), .{ .flow = .down })) { ... }`
  then `group.end(cx)`: a 28 px header with a chevron that eases between closed and open, over
  a section the app draws only while open; with a fit height it folds. A click, or Space or
  Enter while focused, flips it (`Action.toggled`).
- **ColumnHeader.** Up to 16 labelled columns, each with a width and a minimum; the last spans
  the rest. A click on a label sorts by it (again flips the direction, `Action.sorted`), the
  right edge of every column but the last drags to resize within its minimum and the room the
  other columns leave (`Action.resized`; a double press restores it), and `cell(row_rect, i)`
  is the span a table's row draws column `i` into. The header sorts nothing: the app sorts
  its rows by `sort`.

### Window Chrome

An app can draw its own title bar. The window manager still moves, resizes, maximizes, and
closes the window; the app's areas only ask it to.

- **Decorations.** `config.decorations` (`.server` by default) is who should draw the frame;
  `--decorations client|server` overrides it natively. For `.server` the host asks through
  `zxdg_decoration_manager_v1` and `cx.window_state().decorations` reports the answer
  (`.client` where the compositor has no manager); `.client` asks nothing. Headless and the
  browser report `.client`.
- **The window's state.** `cx.window_state()`: maximized, fullscreen, activated, the tiled
  sides, the decorations, and which requests the window manager honours (`wm_capabilities`).
  A change arrives as a `window_state` event and owes a draw.
- **Areas.** `widgets.window_drag(cx, id, rect)` records a drag area (record it before what
  sits on the bar): a press moves the window, a double press maximizes or restores, and a
  right press opens the window manager's menu. `widgets.window_edges(cx, id)`, the last call
  of `draw`, records 4 px resize strips and 12 px corners over the window with resize cursors,
  none while maximized, fullscreen, or server-decorated, and none on a tiled side. A press on
  either never reaches a widget and captures nothing.
- **Requests.** `cx.minimize()`, `cx.toggle_maximize()`, and `cx.close()`; the compositor's
  close arrives as `close_requested`, which closes unless the app calls `cx.keep_open()`.
  Natively each becomes an `xdg_toplevel` request with the press's serial. The browser drops
  them, and a bench replay simulates them (`bench.serve_window`: maximize flips the state).
- **WindowButtons.** Minimize (where the window manager offers it), maximize or restore, and
  close, 46 px each in a row; nothing under server decorations (`width(cx)` says how wide).
- **MenuBar.** `widgets.MenuBar.init(id, titles, items)`: titles side by side, each opening its
  `Menu` below it on a press. While one is open, moving onto another title switches to it, and
  Left and Right move between the menus. `Action` is `opened`, `chosen{menu, item}`, or
  `closed`; `draw_overlay` draws the open menu (through `ui.overlays`).

On Hyprland (0.56) the compositor answers `server_side`, so the gallery shows its window
buttons only with `--decorations client`, and it reports even a floating window as maximized
and tiled on every side, so no resize edges are recorded there.

### Dock

`widgets.Dock` arranges panels the app draws in a tree of splits and tab sets, which the user
rearranges by dragging tabs (steps 45 and 46):

```zig
app.dock.init(ui.id("dock", 0), &labels);          // a panel's id is its index in `labels`
app.dock.add(app.dock.root, editor);                // the root: an empty set at first
_ = app.dock.split(app.dock.root, .left, files, 0.2).?;   // files on the left, a fifth

app.dock.begin(cx, ui.sized(.fill, .fill));
while (app.dock.next(cx)) |panel| switch (panel.id) {
    files => app.draw_files(cx),                    // into the panel's page, a clipped column
    editor => app.code.draw(cx, ui.sized(.fill, .fill)),
    else => {},
};
app.dock.end(cx);

switch (app.dock.handle(cx, event)) { .activated, .closed, .moved => |panel| ..., else => {} }
```

- **The tree** is `widgets.dock_nodes_max` (64) nodes: splits (a `Splitter` each, its ratio
  pane a's share) and sets (up to 16 panels in closable, movable `Tabs`), walked with an
  explicit stack. An empty set collapses, and its split's other child takes its place.
- **Drops.** A tab dragged over a set's page shows one of five zones: the centre joins the set,
  a side (the outer quarter) splits it in half with the panel on that side. Near the dock's
  edges, strips that exist only while a drag is in flight split the whole layout, the new pane
  a quarter. A tab dropped on a bar joins it at that place. A split needs two free nodes; a
  full dock refuses it and the tab stays.
- **Ownership.** The app draws panels and names them; the dock keeps where they are. `close`,
  `show`, `set_of`, and `tab_id` are there for an app's own commands.
- **Save and load.** `save` writes the layout as at most `widgets.dock_save_max` bytes;
  `load` checks every rule (the header, the exact length, children used once and reached once
  from the root, each panel once, only the root empty) before it replaces anything, and a
  refused load changes nothing.

## Example Applications

Worked coordinates, initial values, palettes, and budgets live in the examples' tests, not
here, so they cannot drift. Run `zig build test` for the checked numbers.

### 1. Synthesizer Rack (`examples/sound/rack.zig`)

A modular rack under a header bar: a column of panels, three holding a row of knobs and a
level meter and the fourth four envelope knobs and an envelope display, with patch cables
between knobs, beside a scrolling list of 1,000 presets and a status line. It demonstrates:
- **Layout while drawing.** Nested `begin` and `end` with `share(4)` panels; the knob and
  meter omission rules are a few lines against `cx.remaining()` and `cx.fits()`. The worked
  layouts are locked by the tests in `examples/sound/rack.zig`.
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
- **An app-defined draw type** (`examples/sound/rack/led.zig`). `Led` is an `extern struct` plus a
  WGSL `pixel` function, registered in `config.draw` with no library edit. Each voice panel's
  LED sits in the title band over the meter and glows with the meter level.
- **An image texture** (`examples/sound/rack/badge.zig`). `init` generates a 32 by 32 RGBA badge,
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
- **Audio-driven meters.** The rack plays Thrum's test tone through the producer seam
  (Producers below; `examples/sound/tone.zig`): a PipeWire device natively and Thrum's worklet
  in the browser, both audible. Space (when no title is being renamed) starts and stops it
  ("tone on", "tone off"). Each block's L, R, and mid peaks go through `thrum.level.Ballistics`
  onto the osc, filter, and amp meters, and the LEDs follow. Dragging a knob never changes a
  bar. The rack has no timer: stopped, no stream is open, it draws empty meters, and it sleeps
  (before step 26 a 30 Hz timer woke it forever).

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

### 7. Audio (`examples/sound/audio.zig`)

Stereo meters (RMS fill, peak line, and a one-second hold on a 60 dB scale), a scope of 512
frames triggered on L's rising zero crossing, and an XY trace of L against R on a feedback
target with persistence, all fed by Thrum's test tone (220 and 330 Hz with slow gain
triangles, `thrum/examples/testtone`) through the producer seam, plus a line of blocks received
and dropped. It is the worked example of a peer's audio through the seam: `tone.zig` opens a
`thrum.pipewire.Device` on Space natively (audible), steps an offline `thrum.Engine` in
`produce` where no device plays, and in a page `tone.js` runs Thrum's worklet from the app's own
wasm. Space starts and stops the tone; stopped, the meters reset, the XY trail decays for 44
frames, and the screen sleeps. Scenarios: `still` and `play` (`produce` renders 6, 6, 6, 7
blocks per frame at 60 fps, so dumps are deterministic); their goldens are the lines the app
had before it moved (step 55). At 2856 by 2514 a playing frame costs about 28
microseconds of CPU on the RTX 3060 (41 on the UHD 770) plus 1.6 microseconds per block to
render the tone and 0.4 to drain it; the never-started screen is bitwise identical natively
and in Chromium.

### 7a. Wake (`examples/wake/app.zig`)

A producer makes a value every 5 ms of a 48 kHz clock, a one-second sine, into the app's own
ring and notifies its `patchwork.Wake`; `drain` takes them into a history of 256, drawn as a
sparkline with the ticks, the values drained, and the drops. Space starts and stops it. Natively
the producer is a thread that `args` starts and that waits on a futex while stopped, so a stopped
window sleeps; in regress `produce` steps it by frame (scenarios `idle`, `run`, `stop`); in the
browser its `app.js` runs an interval while the wasm's import says so. Both adapters' frames and
Chromium's are equal.

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
than through `ui.route`. The title bar is the window's chrome (step 43, see Window Chrome): a
drag area under a File / Edit / View `MenuBar`, a Run button, and `WindowButtons` (shown with
`--decorations client`). A "light" toggle in the title bar switches the whole app between
`theme.dark` and `theme.light` (`cx.set_theme`); the widgets' stored colors (slider paints,
knob accents, the field's text) are restyled from the scheme, while the buttons keep their own
blue.

- **basics** (steps 30 to 32): three buttons, two sliders, four knobs with rings of 56, 40, 56,
  and 72, three toggles, a meter that follows slider 0, a form group (step 41: a name field
  with a hint, a secret password field and a search field with icons, a Sine / Saw / Square
  `Segmented` bar, and checkboxes "loop", "sync", and the mixed "all voices"), and a list of 40
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
- **type** (step 36, see Fonts): the gallery adds an `icons` face (Lucide, subset to 14 icons).
  A transport of icon buttons (skip back, play, which turns into pause, stop, record, loop) and
  a toolbar (open, save, settings, each with a tooltip) are `widgets.ButtonOf` a small skin that
  draws the default face and the icon with `kit.icon`; a ladder draws one icon at 12, 16, 24,
  32, and 48 px, the icon set every icon at 24 px, and (step 38, see Text) a `Splitter` of a
  line in each Noto face beside a panel of wrapped text: three bullets of a bold lead and the
  rest (`text.place_runs_wrapped`) and a `widgets.Paragraph`, in a view that scrolls them when
  they do not fit.
- **files** (step 37, see File Drops): a drop zone that lights its border while files are
  dragged over it, the dropped files in a `ListBox` with sizes and statuses ("reading 42%",
  "done", "folder"), and the first WAV among them decoded chunk by chunk
  (`examples/gallery/wav.zig`) and drawn as a waveform. A WAV longer than 21.8 s cancels itself
  at the sample cap ("cut at 21.8 s"); other files are counted, not stored.
- **data** (step 42, see Trees and Tables): a project tree of the repository's own files beside
  a table of the selected folder's children under a name / kind / size `ColumnHeader` (the page
  sorts them), and a property grid of three `Disclosure` groups (`examples/gallery/data.zig`).
- **code** (step 44, see Code Editor): the code editor in two languages side by side in a
  `Splitter`: `EditorOf(c)` on a C sample and `EditorOf(xml)` on a designer-like XML layout
  (`examples/gallery/code.zig`). `c.zig` and `xml.zig` are recipes, languages an app copies
  rather than imports; the light toggle gives both editors their light palettes.
- **tabs** (step 45, see Containers and Drags Between Widgets): two movable, closable tab bars
  side by side over the page's own arrays (`examples/gallery/tabs.zig`): drag a tab to reorder
  it, off its bar onto the other (its ghost follows the pointer), close it with its "×" or a
  middle press, and Reset both.
- **glass** (step 40, see Backdrops and Glass): sixteen album cards (gradients between the
  scheme's accents) scroll in a view under a glass sidebar (`widgets.Panel` with the page's
  material), a segmented bar that picks it (Clear, Frosted, Tinted, Solid), and a transport
  bar whose position slider is `widgets.SliderOf(glass.LensSkin)`, its knob a clear glass lens
  on the popup level. The sidebar's output dropdown opens a glass list that blurs the sidebar.
- **surfaces** (step 39, see Surfaces): a music-player-like page of surfaces alone
  (`examples/gallery/surfaces.zig`): a faint gradient backdrop, a glass-like panel and pill bar
  (translucent, rim-lit, shadowed, not blurred), and six cards of a muted gradient, a radial
  highlight, and a label pill, every colour derived from the theme so the light toggle restyles
  it. The pills, rows, and cards are clickable: hover lights them and a
  press darkens them through `kit.lit`, a pill or row becomes the selection, and a card is named
  on the status line.

Scenarios: `still`, `interact` (a click, two drags, a toggle, typing, a wheel, and a row click,
then settled), `hover` (the pointer rests on button 1), `light` (the toggle, then the focused
field with "abc" selected, settled), and `hardware` (hardware knob 0 dragged up 40 px, hardware
button 1 clicked, hardware toggle 0 flipped, settled) on the basics page; `dropdown` (Down twice
and Enter: "dropdown changed 2"), `menu-open`, `menu-flip`, `context` (right click, Reset),
`dismiss` (an outside click closes the menu and opens nothing), `tooltip`, and `about` for the
popups; `tabs` (each tab clicked: the containers page), `split` (the divider dragged 120 px
left), `list` (row 3 clicked, then Down 20 times: preset 0024 scrolled into view), and `number`
(the frequency dragged up 40 px, the gain double-clicked, "-6.5" typed, Enter) for the
containers; `type` (the type page), `transport` (play clicked: pause shows), `wrap` (the
type divider dragged 240 px left), and `wrap-narrow` (dragged to the wrapped pane's 200 px
minimum: a long word breaks between letters), and `wrap-scroll` (that, then the wheel: the
wrapped text, in a view, scrolled to its end) for the type page; `files` (the empty page), `drop-hover` (files dragged over the zone), and `drop` (a 1 s
tone, a text file, and a folder dropped: the tone's waveform) for the files page; and
`surfaces` (the surfaces page), `surfaces-click` (the Radio pill, the Browse row, and the
Slate card clicked, then Moss hovered), and `surfaces-light` (the page in the light theme);
`glass` (frosted), `glass-scroll` (the wheel every frame, for benches), `glass-popup` (the
output list over the sidebar), `glass-clear`, and `glass-light` for the glass page; `form`
(Saw picked, "loop" ticked, "hunter2" typed into the password field: seven bullets) and
`form-search` (the mixed box turned on, "saw" typed into the search field) for the form group;
and `data` (the page), `tree` (keys from src into widgets, expanded), `sort` (src's children by
size, descending, and the name column dragged wider), and `groups` (transform closed, layout
opened) for the data page; `menubar` (File clicked, Edit hovered, Right to View, Down: Dark
highlighted) and `chrome` (a double click on the bar, which the replay maximizes: restore
shows; Run clicked; close hovered) for the title bar; `code` (the page) and `code-edit` (`/*`
typed before `typedef struct {`: the lines below turn to comment down to the next `*/`), and
`code-light` (both editors in their light palettes) for the code page; `tab-close` (app.zig
closed), `tab-move` (main.zig dragged past ui.zig), `tab-drag` (app.zig dragged onto the right
bar between README.md and build.zig), and `tab-ghost` (ui.zig held over that gap: its ghost
and the insertion marker) for the tabs page.

### 10. Docking Workspace (`examples/workspace/app.zig`)

Four panels in a `widgets.Dock` on a fixed 1280 by 704 screen: files (a `ListBox`), editor
(`EditorOf(c)` on a C sample, the gallery's recipe copied), log (the dock's last eight
actions), and appearance (a light toggle). Dragging a tab joins or splits panels, moves it to
the dock's edge, or reorders it; Save keeps the layout as bytes, Load restores it, and Reset
rebuilds the default. Scenarios: `still`; `dock-centre` (log into the editor's set),
`dock-left`, `dock-right`, `dock-top`, and `dock-bottom` (appearance onto each side of the
editor), `dock-edge` (files held over the dock's right edge, then released: a quarter on the
right), `dock-close` (log's "×"), `dock-resize` (the files divider 80 px right), `dock-ghost`
(files held over the editor's right zone: the overlay and the ghost), and `dock-save` (Save,
close log, Load: the default again).

### 11. Live-Coding Session (`examples/session/app.zig`)

A live-coding music screen rebuilt from two photos of another tool, with the public API only:
a patch set in Noto Serif (italic calls, bold declarations, coloured numbers and channels), one
editable `EditorOf(patch)` whose headings are real lines, with widgets in its margins, a compander row of ring knobs over a transfer curve and a
spectrum, upright toggles (one `ToggleOf(Pill)` with an accent each) and knobs at their lines, a
five-strip mixer (pan knobs with arcs from the top, send knobs,
mute and solo, a scope, a fader with a stereo meter, a spectrum, readouts), and a card with a
piano keyboard, the song's overview, and a transport. A section is a line starting `# `, found
in the text, so typing `# Chorus` adds one, with a mark and a fold bracket, and a mark's state
and colour are kept by name. Dragging a heading's `#` moves its section: a ghost follows the
pointer, a line shows the slot, Escape cancels, and the drop is one edit, so one Ctrl+Z restores
the order. The text is the truth for the mix's numbers, as in `live`: toggles, the shimmer and wet knobs,
four faders, four sends, and two mutes are parsed from it (`examples/session/bindings.zig`), and
moving one rewrites its literal, so a typed `level = -20db` moves the fader and a dragged fader
moves the digits. A drag or a run of wheel notches is one undo entry, and Ctrl+Z reaches the
text with nothing focused. A widget whose call is deleted dims, keeps its value, and binds again
when the call returns; a number out of range clamps and is marked. The compander and the mixer
are inline rows after the lines `round :=` and `send =`. The editor has no gutter and is as tall as its content, so the
wheel scrolls the document through it; margin widgets anchor to `rect_of` by what a line starts
with, so they follow an edit. While the editor has focus, Space and the tracker keys type. The
view and the card follow the window. Space or the play mark starts a 33 ms timer; paused, the screen sleeps.
Scenarios: `still`; `scroll` (to the end: osc, pad, reverb tank), `play` (about a second),
`mix` (pads panned right, bass fader up, pads muted, line soloed, eq off), `knobs` (below, down, and wet turned),
`keys` (E4 held, the mix section off), `edit` (a click after `saws` and typing), `select` (a
double click in italics and Shift+Down), `undo`, `section` (`# chorus` typed at the end),
`rename` (a heading edited), `reorder` (`# reverb tank` dragged above `# pad`), `reorder-hold`
(the same, in flight), `reorder-undo`, `bind-type` (a digit typed into a level), `bind-drag` (a
fader rewrites its digits), `bind-undo`, `bind-toggle`, and `bind-break` (a call deleted).

### 12. Vector (`examples/vector/app.zig`)

`draw.fill` on one screen: a five-point star under non-zero and even-odd, a ring with a closed
stroke in its hole, the region under a plotted curve with its stroke on top, a glyph from
`ttf.load` beside the same glyph from the atlas, a translucent comb tall enough to split into
bands over a bright bar, so a row blended twice would show, and a shape morphing from a circle
to a rounded square on the `frame` event's delta. Space runs the clock, and 1, 2, 3, and 4 pick a
page: the shapes, one `&` an em of the window's height / 1.08, a single band at the
48-segment cap over the whole window, and display text as outlines. Pressing 4 again steps its
three views: `title` ("Patchwork" at 200 px, each letter rocking and pulsing on its own
`Transform`), `write` (a wrapped paragraph written on glyph by glyph, one every 3 frames, which
Space starts over), and `sizes` (a word as outlines beside atlas text at 16, 64, and 512 px,
where the atlas stretches its 160 px raster). Scenarios `still`, `morph`, `glyph`, `curtain`,
`title`, `write`, and `sizes`.

### 13. Touch (`examples/touch/app.zig`)

Several fingers at once, each under its own pointer state: eight pads that light while held, two
`Slider`s moved by two fingers, a `Knob`, and a gesture box whose square a drag moves, a pinch
scales, a two-finger pan moves, a two-finger tap resets, and a long-press turns orange. A HUD shows
the live, most, and refused contacts. The mouse works on all of it, because the app never sees a
touch event. Scenarios `still`, `sliders` (two fingers land on two sliders and move), `chord` (ten
fingers in one step), `pinch`, `two-tap`, `long-press`, and `cancel` (the system takes one finger).

## Touch

A finger is a contact, and the app reads it as the pointer events it already handles
(`src/ui/cx.zig` section 5b, `src/input.zig` section 9). A widget that works for a mouse works under
each finger with no change, and two sliders move at once:

```zig
// Nothing to write: `cx.hit(id, event)` answers for the finger whose event is being dispatched.
// To ask which finger, or whether one holds a widget:
if (cx.touch()) |finger| {
    // finger.id, .primary, .phase (.down .move .up .cancel), .x, .y, .origin, .target, .joined
}
const busy = cx.holds(grip_id);           // the mouse or any finger holds it, in any phase
const live = cx.contacts_live();          // fingers down now; contacts_most, contacts_refused
```

- **Contacts.** `touch_down` claims one of 16 slots (`input.contact_cap`), each with its own
  pointer state (`hot`, `hover`, `capture`, the press flags), swapped into the context for the
  dispatch of that finger's events. A 17th finger is counted in `contacts_refused` and its later
  events do nothing. A `touch_down` of an id still down cancels that contact first, so a lost lift
  cannot outlast the next press, and `touch_cancel` with no id cancels every contact. Moves coalesce
  per contact in the event queue, so ten fingers hold ten slots.
- **Primary.** The first finger down, with none other live, is primary (the Pointer Events rule).
  Only it moves focus, presses a window area, or begins a drag between widgets; a second finger on
  a pad leaves a menu open and a field focused.
- **Joined and `primary_only`.** A finger pressing an area another pointer holds does not capture it:
  widgets see nothing, and `touch().target` and `joined` say what it landed on. A widget of several
  ids that shares press state (tabs, column headers, list and tree rows, menus, dropdowns, text
  fields, the editor, window chrome) flags its areas `ui.cx.primary_flag` or `Flags.primary_only`, so
  a second finger treats them as absent.
- **Hover** of a finger is what it pressed, down to its lift. A double tap counts two contacts
  within 400 ms and 12 px.
- **Hosts.** Natively `wl_touch` (seat capability 4) queues `touch_down`, `touch_move`, `touch_up`,
  and `touch_cancel`; the compositor's cancel ends every finger. In the browser the canvas has
  `touch-action: none`, every finger takes pointer capture, and `pointerType` `"touch"` goes through
  `wasm.touch_*`. Hyprland needs the digitizer mapped to its output or no touch event arrives
  (`hyprctl eval 'hl.config({ input = { touchdevice = { output = "HDMI-A-3" } } })'`).
- **Scenarios.** `bench.Step.touch` lists `Finger`s (`down`, `move`, `up`, `cancel` at absolute
  points), all in one frame, so a chord is one step.

### Gestures

`ui.gestures.Recognizer` is a pure value a widget or app opts into, one per target. It reports tap,
drag, long-press, pinch, two-finger tap, and two-finger pan by a fixed conflict table (a move past
12 px beats a tap and a long-press, a second finger within 80 ms makes the two-finger set, and so
on):

```zig
var rec: ui.gestures.Recognizer = .init(.all, .{});     // Mask, Thresholds
// event: one gesture per call; a pinch and a pan on one move are one `two_finger`.
switch (rec.handle(cx, box_id, event)) {
    .tap, .long_press, .two_finger_tap => |spot| {},
    .drag => |drag| {},                                  // .phase .began .changed .ended .cancelled
    .two_finger => |two| {},                             // .scale, .pinching, .panning, .dx, .dy
    .none => {},
}
```

It tracks at most two contacts on its target and uses only those whose press landed on it, so two
fingers on different areas never pinch. With a mouse it runs the one-finger set from the left
button. A long-press counts `.frame` deltas and keeps the app animating only while one is pending,
so the app sleeps after at most 400 ms. Thresholds are in `ui.gestures.Thresholds`, and `feed` and
`tick` are pure for tests.

## Drags Between Widgets

A widget that holds a press may turn it into a drag that another widget receives: a tab
dragged from one bar to another, later a dock panel. The payload is a `u64` the app interprets.

```zig
// source, on its drag hit (a threshold of its own choosing): start the drag.
cx.drag_begin(tab_id, key);
// source, draw: a ghost at the pointer while `cx.dragging()` names it.
if (cx.dragging()) |drag| if (drag.source == tab_id) draw_ghost(drag.x, drag.y);

// target, draw: one area flagged `drag_target`; a marker while a drag is over it.
cx.area(bar, rect, 0, ui.cx.drag_target_flag);
const lit = cx.drag_hovering(bar);
// target, event:
switch (cx.drag_hit(bar, event)) {
    .dropped => |over| insert(over.payload, over.x),
    .drag_in, .over, .drag_out, .ended, .none => {},
}
// source, event: `.ended = { target, cancelled }` once the drag is over.
```

- **One at a time,** riding on the source's capture: `cx.hit` is unchanged, so the source
  still sees its `drag` and `up` and ignores them while a drag of its own is in flight.
- **The target** is the topmost area flagged `drag_target` under the pointer, on a layer at
  least the hot area's, so a popup blocks it, resolved at every pointer event from the one
  after `drag_begin`. `drag_in`, `over`, and `drag_out` follow it; the left release gives the
  target `dropped` and the source `ended { target }`.
- **Cancel.** Escape or the pointer leaving the window gives the target `drag_out` and the
  source `ended { .none, cancelled }`; the press stays held until its release.
- **Drawing** needs no state: `dragging()` and `drag_hovering(id)` answer in any phase, every
  pointer event of a drag owes a draw, and the cursor reads `grabbing`.
- **Separate from file drops.** Their events, lifetimes, and flags differ (a file drop holds no
  capture and streams chunks later), so a file zone never receives a tab and a tab bar never
  files.
- **Bench step** `hold` presses and moves without releasing, so a dump shows a drag in flight;
  `drag` releases, which drops.

## File Drops

A drag of files from a file manager (natively) or from the desktop (in the browser) reaches
the app as events, and the files' bytes follow in chunks; the app never sees a path.

```zig
const zone = ui.id("zone", 0);

// draw: one area flagged `drop`; highlight while a drag is over it.
cx.area(zone, rect, radius, ui.cx.drop_flag);
const lit = cx.drop_hovering(zone);

// event: accept what you want, store the chunks yourself.
switch (cx.drop_hit(zone, event)) {
    .drop_in, .drop_out => cx.redraw(),
    .dropped => |dropped| cx.accept_files(zone, mask_of(dropped.files)),
    .file => |chunk| store(chunk.file, chunk.offset, chunk.bytes, chunk.end),
    .none => {},
}
```

- **The target** is the topmost area flagged `drop` under the drag, resolved like the wheel
  target, so a popup blocks drops beneath it. The pointer, hover, and focus are untouched;
  `cx.hit` answers `none` for the four drop events and `cx.drop_hit` answers them.
- **The drop** lists up to 16 files by base name (cut to 255 bytes), size, and whether they can
  be read (a folder or a special file cannot); more are counted in `skipped`. During the `drop`
  event the app calls `cx.accept_files(id, mask)` once; `id` then receives the chunks.
- **Chunks.** Accepted files arrive in order, never interleaved, in chunks of exactly 64 KiB
  but the last; the chunk that reaches the file's size is `done`, and every accepted file ends
  with exactly one of `done`, `failed`, or `cancelled`. An empty file is one empty `done`. The
  bytes are valid only while the chunk is dispatched: copy what you keep into your own static
  storage. One state machine (`patchwork.drop.Transfer`) cuts the chunks for every host, so a
  decoder sees the same splits natively, in the browser, and in regress.
- **Big files** stream at any size. Refuse one up front by not accepting it, or stop it with
  `cx.cancel_files(mask)`: its `cancelled` chunk follows, and the other files go on.
- **Natively** (`src/host/dnd.zig`) a drag offering `text/uri-list` is taken at
  `wl_data_device_manager` version 3: copy only, and `accept` is sent exactly while a drop
  target is under the drag, so the compositor shows a copy cursor over drop zones only. The
  list arrives through a pipe in the poll set; each `file:` path is examined with `statx`, and
  a non-regular file is never opened. Files are read with `pread` on the UI thread, at most four
  chunks per wake, and the loop does not sleep while a transfer runs.
- **In the browser** `dragover` and `drop` on the canvas call into Wasm, the drop effect is
  "copy" over a target and "none" elsewhere, and `File.slice` reads each chunk; the page itself
  ignores drops beside the canvas.
- **Bench steps** `drop_hover` and `drop` (files given as repeated byte parts) replay a drop
  from memory in every host (`bench.replay_drop`).

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

## Data From Another Thread

Step 54's seam, for any producer: a peer library's audio thread and its monitor (Thrum's, as
`examples/sound` shows), a worker, a socket reader. The app owns the queue between the two,
which any app can write; Patchwork owns the sleep.
- **The wake.** `patchwork.Wake` (`src/wake.zig`) is a field of the app, initialized in `init`.
  The native window host attaches its `eventfd` right after `init` and before `args`, so a thread
  `args` starts can call `wake.notify()` after each item it publishes. Notify writes only when
  the UI armed the wake before sleeping, so while frames flow it costs one atomic swap.
- **The count.** `pending` returns what is waiting, loaded `seq_cst`, with the producer's publish
  `seq_cst` too: the host arms the wake, then reads the count, so an item published just before
  the sleep is never missed. Thrum's monitor queue is published this way since its step 23.
- **The drain.** The hosts call `drain(app, cx)` once a wake, before `ui.animate`, and once a frame while frames are presented; it pops what it wants and calls
  `cx.redraw()`.
- **By frame.** Regress, the native bench, and a browser replay run no producer thread: each
  frame they call `produce(app, frames)` with `bench.producer_frames_at(k, fps)`, 800 frames a
  frame at 60 fps, and then `drain`, so a scenario renders the same frames on every run.
- **In a browser.** The producer lives in the page: the app's web module (`web_module`, served as
  `/app.js`) imports functions into the wasm, copies data in through the app's own exports, and
  calls `shell.wake()` to schedule the frame whose `tick` drains (see Browser below). A peer's
  worklet or worker is started from a wasm import called in an input handler, which has the
  page's user activation, and its files are `web_files`.
- `examples/wake` is the whole seam with no peer: a producer of 200 values a second on a thread,
  in regress by frame, and in the page on an interval, with its own `app.js`.

## Bench Mode

`src/bench.zig` and the native host measure frames on request; without `--bench` nothing of
it runs, no GPU feature is requested, and the frame path is unchanged.

```text
<app> [--adapter low|high] [--no-cache] [--check] [--decorations client|server]
      [--bench [scenario] [--frames N] [--dump out.ppm] [--csv out.csv]]
      [--] [arguments for an app that declares `args`]
<app> --render <scenario> [--size WxH] [--scale S] [--fps N] [--frames N]
      [--adapter low|high] [--no-cache] --out <dir>|-
zig build bench-<example> -Doptimize=ReleaseFast -- <scenario> [options]
```

- **Scenarios.** An app declares `pub const scenarios: []const bench.Scenario`: a `setup`
  list run once and a `cycle` list repeated while `frames` frames are measured. Steps are
  `key`, `click` and `click_at` (an area of the last frame, by `bench.area(name, index)`),
  `right_click` (a right press and release at a point, for a context menu), `wheel`, `hover` (a move to a point that stays, so hover animations settle), `drag` (press,
  move by a delta, release; a zero delta is refused), `hold` (press, then move by a delta twice
  and stay pressed, so a drag between widgets shows in flight), `release` (move to a point and
  release there, ending a hold a frame later), `touch` (fingers going down, moving, lifting, or
  cancelled at absolute points, all in one frame), and `wait`. Each step runs when the host is idle and presents one frame; an empty
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
- **Render.** `--render` writes a scenario's frames instead of timing them (see Rendering
  Frames).
- **A producer.** No producer thread runs in bench mode: each frame calls `produce` with
  `bench.producer_frames_at` and then `drain`, so dumps are deterministic.
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
  it opens an `Offscreen` (see Rendering Frames): a device with no surface and a `bgra8unorm`
  target that stands in for the swapchain (`gpu_wgpu.headless_target_create`): acquiring
  returns it, presenting is a no-op, so the renderer's stream replays unchanged. Every scenario with `regress = true` (the
  default) renders cache on and off, each from fresh state (app, UI context, renderer, and GPU
  tables re-created), at 1280 x 720 and scale 1 (`pub const regress_size: [2]u32` overrides,
  1 to 4096 a side), and the last frame's RGB rows are hashed (XxHash64, seed 0).
- **Clock.** Frame `n` is at `n * 1000 / 60` ms: the step of that frame, then every app timer
  tick due by then (each at its own multiple of the period), `ui.animate` by 1/60 s, a
  producer's `produce` and `drain` (`bench.producer_frames_at`), and the draw. Nothing reads
  wall time, so timer and producer scenarios (wave `play`, wake `run`) give the same hash every
  run.
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
  the scenario on the same clock (input and the interval timer are off, and an app's web module
  keeps its producer off).
  `tools/browser_check.py <app> <scenario>` (standard library only) renders the headless
  frame, serves the app, drives system Chromium over CDP, and compares the screenshot: it
  passes at a maximum difference of 3 levels on at most 0.1% of the pixels, and reports
  console errors. `--root DIR` checks an app in another tree, a package of its own: the
  executable, the reference frame, and the `serve-<app>` step are all taken from `DIR`.

## Rendering Frames

`--render` writes a scenario's frames with no window, at any size, scale, and frame rate. It is
native only: the browser renders live. Every frame the scenario draws is written, from frame 0,
so a scenario's frame count is its `setup` plus `frames` plus one.

```bash
./zig-out/bin/gallery --render still --out frames
./zig-out/bin/fx --render scope --size 1920x1080 --scale 2 --fps 60 --frames 600 --out - \
  | ffmpeg -f rawvideo -pix_fmt rgba -s 3840x2160 -r 60 -i - -c:v libx264 -pix_fmt yuv420p scope.mp4
```

- **Size.** `--size` is logical pixels (the regress size without it) and `--scale` the display
  scale, 0.25 to 16. Device pixels follow the window's rule, `round(logical * scale)` rounding
  half up, so 1366 at 1.25 is 1708. A side is at most 8192 device pixels, and a frame must fit
  `pub const render_size_max: [2]u32` (device pixels, at least the regress size, 3840 x 2160 by
  default), the size of a static buffer that only `--render` touches.
- **Rate.** `--fps` is 10 to 240. Frame `n` is at `n * 1000 / fps` ms in whole milliseconds, the
  app timer ticks as time passes each multiple of its period, and a producer's frames follow
  the rate (`bench.producer_frames_at`), 48,000 a second at every rate. The output is the same
  bytes every run.
- **Output.** `--out <dir>` writes `<dir>/<scenario>-000000.png` and so on (RGB, stored, about
  24.9 MB a frame at 4K, so use a pipe for a video). `--out -` writes raw RGBA frames back to
  back on stdout and nothing else; the encoder sets the pace, and a closed pipe ends the run
  with "output closed after N frames", exit 1. Frames are opaque: alpha is 255.
- **Report.** One line on stderr: the size, the frame count, the last frame's hash, and the time
  per frame. `draw` is the CPU's side of the frame; the GPU's work is waited on in `read`. At
  the regress size, scale 1, and 60 fps the hash is the scenario's golden on that adapter, a
  check that needs no picture. `--adapter` is `high` by default; `both` is refused.

`--regress` and `--render` are clients of a library type, `patchwork.host.offscreen`, which any
native caller can drive at a time it picks:

```zig
const Off = patchwork.host.offscreen.Offscreen(App);
try Off.open(.{ .width = 1920, .height = 1080, .scale_120 = 240, .fps = 60 });
defer Off.close();
try Off.start(.{ .cache = true });
Off.dispatch(event);                         // or Off.step(step, time_ms); Off.app(), Off.context()
try Off.frame(patchwork.host.offscreen.at_frame(n, 60));
const pixels = try Off.read(.rgba, out);     // out.len == width_px * height_px * 4 (see Off.size_px())
```

`Offscreen` has static storage, so there is one live instance per `App` type. `open` returns
`error.TooLarge` or `error.BadScale` for a size it cannot make. `frame` takes any
`.{ .time_ms, .dt_ms }`, and time may go backwards: the shader clock follows it exactly, timer
ticks fire only as time passes the next multiple of the period, and the app is never rewound, so
a caller that scrubs keeps its state outside the app timer. `read` is separate because a caller
may draw many frames and read one; it blocks until the GPU has caught up.

## Time for a Transport

A transport, a timeline that plays and stops, follows frames, not `timer_period_ms`: period 0,
advance `t` from the `.frame` event, and call `cx.keep_animating()` while playing, as
`examples/vector` does. It sleeps when stopped, and it is the only clock a wasm app has.

```zig
.frame => |dt_ms| {
    if (!app.playing) return;
    app.t_ms += dt_ms;
    cx.redraw();
    cx.keep_animating();
},
```

Pressing play must itself start the frames: the event that sets `playing` calls `cx.redraw()`, and
the next `.frame` keeps them coming.

- Deltas are whole milliseconds and clamp at `animator.dt_max_ms` (100), so a stall loses time.
  That suits motion.
- It does not suit anything locked to sound: there, `t` comes from the sample clock.
- A tool over `Offscreen` sets the app's time itself: `Off.app()`, `Off.context().redraw()`, then
  `frame`.

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
the step 16 op sequences" in `examples/sound/rack.zig`. The path point pool follows the same
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
border, radius, hover, down), `draw.Surface` (a gradient, a rim-lit border, and a soft shadow;
see Surfaces below), `draw.Glass` (a blurred, tinted, refracting view of a backdrop; see
Backdrops and Glass below), `draw.Arc` (open ring), `draw.Glyph` (glyph-atlas text written by
`text.place`), `draw.Image` (an `rgba8` texture), and `draw.Path` (a stroked polyline, see
Paths), and an app adds its own (the rack's `Led`).

**Surfaces.** `kit.surface(cx, rect, clip, look)` appends a `draw.Surface` whose shape is
`rect`:

```zig
kit.surface(cx, card, page_clip, .{
    .fill = .{ 1, 0.55, 0.25, 1 },                  // the gradient's start; alone a flat fill
    .fill_to = .{ 1, 0.25, 0.5, 1 },
    .gradient = .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 1 } } }, // or .radial
    .radius = 18,
    .border = .{ 1, 1, 1, 0.45 }, .border_width = 1, .rim = 0.6,       // lit from the top
    .shadow = .{ .offset = .{ 0, 6 }, .blur = 16, .alpha = 0.35 },      // black, soft
});
```

- **One gradient per record**, linear or radial in the shape's own 0 to 1 space, mixed
  premultiplied so a fade to a transparent stop keeps its colour. A highlight is a second
  surface: a radial one from a light colour to `draw.transparent`.
- **The shadow lives inside the record's rect.** `Surface.of` grows the rect by the reach,
  `1.5 * blur + max(|offset|)`, and the shader insets the shape by it, so the pixel cache,
  alignment shifts, and clips need nothing special. The shadow is a Gaussian of sigma `blur / 2`
  (an `erf` of the box's distance), never shows under the shape, and is cut by `clip`: pass the
  parent's clip. A surface with a blur of 16 rasterizes 1.5 blur past its shape on every side.
- **128 bytes**, the registry's maximum, and no hover or press weights. `kit.lit(look, scheme,
  hover, down)` mixes a look's fill, end stop, and border toward the theme's `lighten` and
  `darken` by the scheme's weights, exactly as `Box`'s shader does, so a clickable surface
  lights and darkens like a box face: `kit.surface(cx, rect, clip, kit.lit(look, cx.theme(),
  item.hover.value, item.down_value()))`. A surface only draws; a widget records its area and
  answers `cx.hit` as any other. `Box` is unchanged.

**Backdrops and Glass.** `cx.drawing().backdrop(layer, blur)` (or `kit.backdrop(cx, layer,
material)`) marks a layer for one frame and returns the id its glass samples. The renderer
draws every layer below it into a window-sized scene, blurs that into a pack with a dual-filter
chain (`src/draw/backdrop.zig`), copies the scene into the main pass with exact bytes, and
continues with the marked layer:

```zig
_ = kit.backdrop(cx, glass_layer, theme.Material.frosted);   // blur sigma 16, logical px
_ = cx.drawing().layer(glass_layer);
if (!kit.glass(cx, sidebar, clip, kit.glass_look(cx.theme(), .frosted, 22)))
    kit.face(cx, sidebar, clip, .{ .fill = cx.theme().colors.panel, .radius = 22 });
```

- **At most two** per frame, one per layer, taking no layer of their own: one under panels and
  one under popups (a `Menu` with a glass material marks `.popup` itself), so a popup's glass
  blurs the glass panel under it. Glass on the same level does not see other glass.
- **The chain** downsamples to half, a quarter, ... (2 to 6 levels) and back up to half, so a
  wide blur costs about what a narrow one does; `backdrop.chain_for(sigma)` picks the levels
  and the tap offset from a variance formula calibrated against a CPU twin of the passes, for
  sigma 2 to 96 device pixels. The pack holds two half-size images: the first down pass (light)
  and the last up pass (heavy).
- **`draw.Glass`** (80 bytes) is a rounded rect over the pack: `frost` mixes light and heavy,
  then `saturation`, a `tint`, a rim toward `theme.lighten` lit from the top left, and
  `refraction`: the edge band (`bevel`) reads the backdrop nearer the centre, so a small disc
  is a lens (the gallery's slider knob). It reads its position from `Pixel.frag`, so it draws
  only in window-sized passes, never on a layer bound to an offscreen target.
- **Only where glass is.** Each chain pass is scissored to the union of the rects of the glass
  that samples it, grown by the chain's reach, which keeps it exact; a backdrop nothing samples
  renders no chain. On the gallery's glass page scrolling at 1901 by 2114, the two chains cost
  0.47 and 0.06 ms of GPU on the UHD 770 (1.71 and 1.45 ms unscissored), and the whole frame
  0.26 ms on the RTX 3060.
- **Cache and idle.** A chain re-renders only when the content below its layer, its region, or
  the size changes; that moves the pack's revision and dirties the glass tiles. Scenes repaint
  only the frame's dirty rects, so a cached frame equals a direct one, and an unchanged frame
  is skipped. A type that declares `pub const backdrop = true` samples a pack (`texture =
  .target`); only a registry with one gives its context backdrops and its renderer the copy,
  down, and up pipelines.

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
  appearance, or `config.draw`'s order with `.registered` (next item). Box, glyph, box, glyph
  in one layer is two draw calls, not four.
- **Draw order inside a layer.** Because a batch draws where its first instance appeared, a
  Box appended after any Glyph on the same layer draws under every glyph: a panel face drawn
  after a title hides nothing, but the title's batch already opened, so labels placed on that
  face draw under it. Append faces before any text on the layer, or put what must cover on a
  higher layer. First appearance also depends on what is on screen, so scrolling can change
  it. `config.batch_order = .registered` fixes the order for the whole app: a layer's batches
  draw in `config.draw`'s order, then by texture, on every frame, so `Box, Waveform, Fill, Arc, Path,
  Glyph` keeps faces under plots under text. Pick it for a new screen; `.appearance` stays the
  default. An app on `.appearance` can call `draw.covered_glyphs(cx.drawing())` in a test, after
  `finalize`: it counts glyphs an opaque box in a later batch of their layer covers, and 0 means
  none are hidden. It is O(boxes * glyphs), a test aid, and needs `Box` and `Glyph` registered.
  The sort key is 16 bits (`layer * 64 + texture`), so up to 64 textures and the
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
_ = draw.path.polygon(cx.drawing(), &points, stroke, clip);            // closed, ?Placed
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
- **Closed strokes.** `polygon` joins the last point to the first with the seam rule, so a
  translucent ring shows no dot at its start. A ring of one chunk has no seam.

The CPU twins (`distance_to_polyline`, `oriented_quad`, `chunk_alpha`, `draw.sdf_segment`)
check the shader's math, the chunk rects and quads, and the seam blending without a GPU.

## Fills

`draw.fill` fills closed contours on the GPU through the `Fill` draw type
(`src/draw/fill.zig`), so a shape that changes every frame uploads only its points:

```zig
var shape: draw.fill.Builder = .init(zoom);       // screen px per logical px; 16 KiB on the stack
shape.move_to(.{ 10, 10 });
shape.line_to(.{ 90, 10 });
shape.quad_to(control, end);
shape.cubic_to(.{ control_a, control_b }, end);
shape.close();                                    // the next move_to or the append closes too
shape.polygon(&points);                           // a closed contour in one call
shape.outline(&ttf_outline, scale, pen);          // a font outline, +y down
shape.set_transform(.around(centre, .rotation(0.3))); // between contours; points map before flattening
const placed = draw.fill.append(cx.drawing(), &shape, .{ .color = color, .rule = .even_odd }, clip);
```

- **Flattening.** Quadratics use the glyph rasterizer's rule (`raster.quad_chords`, at most 16
  chords) at `fill.tolerance_px` of 0.05 px, a quarter of the atlas's 0.2, and cubics the stroke's
  (`path.cubic_segments_at`), both at `zoom`, so pass `cx.text.device_scale()` (the display scale
  times `cx.view_zoom`) for chords that follow the screen. At 0.05 a glyph shows no facets at
  2,000 px and none of the 1,517 glyphs of U+0021 to U+017F is refused; a bitmap's 0.2 showed them.
- **Transforms.** `draw.Transform` is a 2 x 3 affine (`translation`, `scaling`, `rotation`,
  `then`, `around`, `apply`; `+y` down, so a positive angle turns clockwise).
  `Builder.transform` maps every point a call takes, control points included, before any
  flattening, so a rotated or scaled shape takes chords for its size on screen. Set it with
  `set_transform` between contours, never inside one; `reset` restores the identity. A scale of 0
  collapses a shape, which then appends nothing.
- **Bands.** A shape is cut into horizontal bands, halved until each lists at most 48 segments
  (`segments_max`), and each band is one `Fill` instance (80 bytes) whose fragment loops over
  its list. Points are 2 per segment per band it meets. Neighbouring bands share one edge, so a
  translucent shape blends once. A Builder holds 1,024 segments.
- **Coverage.** A fragment sums, over its band's segments, the signed part of its pixel left of
  each: the exact area, as `text/raster.zig` writes it. So corners and hairlines are exact, and
  an edge between two inside regions (the arms of a star) draws nothing. `.non_zero` is
  `min(|sum|, 1)` and `.even_odd` folds the sum. Regions of opposite winding that meet inside one
  pixel stay approximate.
- **Appends are atomic.** A shape over the Builder's cap, a band under 1 logical pixel still over
  48 segments, or a full pool is refused whole and counted in `overflow_count`. A shape with no
  area appends nothing and counts nothing.
- **Paint** is one solid colour with a `hover` mix, and there are no hit areas yet: record a box or
  a path area beside it.

| 3840 x 2160, full redraws | Instances, points | RTX 3060 | UHD 770 |
| --- | --- | --- | --- |
| A 2,000 px `&`, 220 segments | 7, 496 | +0.75 ms | +9.8 ms |
| One band at the cap over the window | 1, 96 | +5.7 ms | +47.8 ms |

The CPU twins (`signed_area`, `coverage`, `band_alpha`) check the shader's math, the bands, and
the seams without a GPU, against `raster.zig` on glyph outlines and polygons.

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
- **Proportional faces.** A language that declares `faces: [N]text.Face`, one per class, is set
  in those faces instead of on the grid, chosen at compile time, so a mono editor keeps its
  code. There is no shaping or kerning: a line is a sum of advances, as in `text.place`.
  `text.FaceSet` holds one pair of tables per distinct face and the line pitch is the faces'
  largest (`editor.line_height_of(L, size)`). A click lands on the nearest boundary, Up and Down
  keep an x instead of a column, and the horizontal range is the widest line in pixels, measured
  once per revision. Tab still inserts spaces to a multiple of four columns, which do not line
  up in a proportional face. It costs 103 KB of pens per editor. `examples/session/patch.zig`
  is the recipe.
- **Line sizes.** With `faces`, a language may declare `scales: [K]f32` (1 to 4, `scales[0]` is
  1, none below it) and `level_of(line) u8`: a line's size is `style.size * scales[level]`, so a
  heading is a taller line of real text that the caret, selection, and undo treat like any
  other. `level_of` sees only the line's bytes, so an edit never changes another line's height.
  The buffer keeps the first `editor.tall_cap` (64) such lines; past them a line is a body line.
  A scaled glyph is one cache lookup each, with no second set of tables. Page Up and Down and
  the bounds stay on the body pitch.
- **Keys.** Arrows, words with Ctrl, goal column on Up and Down, Home, End, Page Up and
  Down, Ctrl+Home and End, Shift selection, Backspace and Delete (words with Ctrl), Enter
  with the line's indent, Tab and Shift+Tab (several selected lines indent and outdent as
  one entry), Ctrl+A, C, X, V, Z, Shift+Z, and Y. Clicks 1, 2, and 3 place the caret, select
  a word, and select a line; a drag extends without scrolling past an edge.
- **Scrolling.** Vertical in a step 14 view (thumb, wheel `dy`); horizontal is the editor's
  own `scroll_x` (wheel `dx`, or `dy` with Shift), clamped by the longest line. Every edit
  and caret move keeps the caret visible. A view with nothing to scroll leaves the wheel to the
  one around it, so an editor as tall as its text scrolls its document. `style.gutter = false`
  drops the line numbers and starts the text `padding_px` in.
- **Bounds.** At most `editor.lines_max` (128, which fills a 2,688 px viewport) lines of
  `editor.columns_max` (200) columns draw, so a draw appends at most `editor.glyph_max`
  (26,112) glyphs. A known viewport bounds it tighter: `editor.glyph_bound(width, height,
  size)` is its lines (`lines_bound`: those whose tops fall inside, plus the cut one) times
  its visible columns plus the gutter digits, callable at compile time, and every draw
  asserts it. The gallery budgets its two editors with it: 6,608 glyphs, not 52,224. In
  proportional faces a width bounds no columns, so `editor.glyph_bound_of(L, width, height,
  size)` allows each drawn line its `columns_max`.
- **Languages.** `editor.EditorOf(L)` is the editor of language `L`, and `editor.Editor` is
  `EditorOf` the patch language (`editor/tokenizer.zig`). A language is a file or struct that
  declares `State` (an `enum(u8)` with a `normal` tag, kept per line: one byte each), `Class`
  (an `enum(u8)` of 1 to 16 tags), `palette` (one colour per class), optionally `faces` (one
  face per class), and
  `next(line, at, state) ?editor.Token(Class)`, which returns a line's tokens one at a time.
  Tokens come in order and are not empty, every byte between them is a space, and they depend
  only on the line and its start state, so the buffer caches start states and re-tokenizes
  after an edit until one matches. `editor.language.check` names the first problem, and
  `EditorOf` makes it a compile error (`"c.Bare: missing ``pub fn next(...)``"`). Colours are
  per instance: `EditorOf(L).default_palette` puts `L.palette` over a dark chrome and
  `light_palette` the optional `L.palette_light` (else `L.palette`) over a light one; an app
  sets `style.palette` when its scheme changes, since the editor never reads the theme. The gallery's `c.zig` and `xml.zig` are recipes:
  copy one into your app; a language moves into the library when three apps need it.
- **Decorations and rows.** The app sets up to 2,048 `Decoration{start, end, kind}` (`box`,
  `strike` over the text on layer 1, `error`) and 32 `InlineRow{after_line, height}`, up to 640
  px high, and
  rebuilds them on a new `revision()`. Rows are filled through
  `draw_begin` / `while (next_row(cx)) |slot|` / `draw_end`; `rect_of(byte)` is the
  character's unclamped logical rect for anchors and `viewport()` the box to clamp against.
- **Programmatic edits.** `replace(range, utf8)` keeps the caret in the text around the range.
  `replace_keeping(range, utf8, after)` takes the selection from the caller and keeps it in the
  undo entry, for an edit that moves text, whose caret should move with it. `undo(cx)` and
  `redo(cx)` are what Ctrl+Z and Ctrl+Y do, for an app that routes them with no focus on the text.
- **Number literals** (`editor.literal`, step 53), for an app that binds widgets to numbers in
  its text. A literal is fixed point, `units / 10^decimals` (`Fixed`), so a widget writes back
  exactly the digits it read: `parse` and `format` round trip every spelling within 9 integer
  digits and 6 decimals, `.25` included. `steps(lo, value, hi)` is a widget's range at the
  value's decimals, `fixed.with_units(units)` the same literal at a new value, and
  `write(&editor, range, fixed)` one `replace` that returns the change in length, which
  `shift(&range, at, delta)` applies to every range the app keeps. The protocol, in the module's
  guide: a parse never writes and a write never parses; a grab opens `gesture_begin`, each step
  writes and shifts, the release closes `gesture_end` (one undo entry) and parses once.
  `examples/live` and `examples/session` follow it; the grammars stay in the apps.

## Text

`patchwork.text` draws three embedded faces: `.sans` (Noto Sans Regular), `.sans_bold` (Noto
Sans Bold), and `.mono` (Noto Sans Mono Regular), all SIL OFL 1.1 (`src/text/fonts/OFL.txt`),
and any the app adds (see Fonts).
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

**Wrapped text.** `text.place_wrapped` and `text.place_runs_wrapped` break text into lines no
wider than `rect.width`; `text.measure_wrapped` and `measure_runs_wrapped` give the height
(lines times `text.line_height`, the face's line rounded up to a whole logical pixel), and
`text.Lines` is the pure iterator both use. Lines break after spaces (which hang past the
line's end), after a hyphen unless a digit follows ("-6.5" stays whole), and at `\n`; a word
wider than the line breaks between letters, and a run boundary is never a break. Each line
aligns by `WrapOptions.align_x`, the block by `align_y`, and each baseline snaps to the device
grid; lines outside the clip cost no cache lookups. `widgets.Paragraph` (one style, passive
like `Label`) takes a `.fit` height as the height of its lines at the width it gets:

```zig
const intro: widgets.Paragraph = .{ .text = words, .style = body };
_ = intro.draw(cx, ui.sized(.fill, .fit));                    // as tall as its lines
// Mixed styles (a bold word in a sentence): measure, walk, place.
const height = text.measure_runs_wrapped(&runs, width);
const rect = cx.walk(ui.sized(.fill, .{ .fixed = height }));
text.place_runs_wrapped(cx.drawing(), &runs, rect, clip, .{}); // WrapOptions: start, start
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

**Text as outlines.** Atlas glyphs are bitmaps at the size they were cached for: they cannot
rotate, a raster stops at 160 px and stretches above it, and `Style.size` stops at
`text.size_max` (512). Display text that rotates, grows, morphs, or is written on draws each glyph
as a `draw.Fill` shape instead, at any size. It is a second way, never a replacement: at UI sizes
the atlas's snapped bitmaps are as sharp and cheaper, and nothing switches by itself. The draw
context must register `draw.Fill` (a compile error names it otherwise).

```zig
// One shape per glyph, in `place`'s layout: place, place_runs, place_wrapped, place_runs_wrapped.
text.place_outlines(cx.drawing(), style, "Patchwork", rect, clip, options);
// Your own loop: each glyph's pen before snapping, a transform, a colour, a progress.
var glyphs: text.Glyphs = .wrapped(&runs, rect, .{});          // or .line(&runs, rect, options)
var shape: draw.fill.Builder = .init(cx.text.device_scale());
while (glyphs.next()) |glyph| {                                // every codepoint, spaces too
    shape.reset();
    shape.set_transform(.around(glyph.pen, .scaling(local, local)));
    if (!text.contours(&shape, glyph.style.face, glyph.glyph, glyph.style.size, glyph.pen)) continue;
    _ = draw.fill.append(cx.drawing(), &shape, .{ .color = glyph.style.color }, clip);
}
```

- **`text.Glyphs`** is pure: it holds no cache and never touches the draw context, so it works
  for a time that is not this frame. A `Glyph` has the glyph id, codepoint, style, the pen and
  baseline in logical pixels (`place`'s before snapping, so `round(pen[1] * scale)` is its
  baseline row), the advance, the `line`, and the `index` among the codepoints yielded.
- **One shape per glyph,** so a refused glyph (a full point pool: about 800 to 1,400 glyphs
  fill it) is counted in `overflow_count` and the next still draws. A glyph whose box misses the
  clip is skipped before its outline loads. A glyph costs about 0.6 microseconds on the CPU, so
  there is no outline cache. A book page on screen is an atlas job.
- **No hinting, kerning, or snapping,** so advances match the atlas's and rotated small text is
  softer than bitmaps. CFF outlines are not read (`ttf.zig` reads `glyf` only).

Module guides in `src/text.zig` and `src/text/*.zig` hold the algebra; the tests hold the
worked numbers (the rasterizer is checked against a polygon-clipping reference).

## Fonts

An app adds faces of its own beside the library's three with `AppOptions.fonts`, at most
`patchwork.app_face_max` (5), so eight in all. Each goes through the same build-time path as
the Noto faces: subset by `tools/subset.zig`, embedded by the generated `patchwork_fonts`
module, parsed at compile time. `text.Face` is generated per app: the library's `.sans`,
`.sans_bold`, and `.mono` at 0, 1, and 2, then the app's names in order, so `.{ .face =
.icons }` compiles only in an app that added `icons`.

```zig
const icons = @import("src/icons.zig"); // the app's codepoints and their ranges
const steps = patchwork.addApp(b, dep.builder, .{
    .name = "synth",
    .root_source_file = b.path("src/app.zig"),
    .target = target,
    .optimize = optimize,
    .fonts = &.{.{ .name = "icons", .source = b.path("fonts/lucide.ttf"), .ranges = &icons.ranges }},
});
```

- **The face.** TrueType with `glyf` outlines, any units per em (16 to 16384), a Unicode
  `cmap` of format 12 or 4. A CFF (`.otf`) face fails the build naming the file. Commit its
  licence next to it.
- **The name** is a Zig identifier other than `sans`, `sans_bold`, and `mono`, used once; it
  becomes the `text.Face` tag. `addApp` checks the list at configure time and panics naming the
  face and the rule.
- **Ranges.** `ranges` lists the codepoints to keep, increasing and apart; null keeps the app's
  `font_ranges` (null there too: the whole face). Keep them tight: the gallery's 917 KB Lucide
  face subset to its 14 icons is 4.5 KB, so its `gallery.wasm` grew by 10 KB with the page's
  code. Name the codepoints in one file the app and its `build.zig` both import, as
  `examples/gallery/icons.zig` does, so they cannot drift apart.
- **Drawing.** Text in an app face is a `text.Style` like any other. For icons,
  `kit.icon(cx, face, codepoint, size, rect, clip, color)` (`text.icon` on the draw context)
  centres the glyph's ink on `rect`, snapped to the device grid: icon fonts' advances and
  baselines vary, and centring the ink lines them up in buttons. A codepoint the face does not
  map draws nothing and is logged once per change, like an overflow (`icons: 1 drawn this
  frame are not in their face (last U+E13C in icons)`).
- **Icons from a font or as a draw type?** A font for many small standard icons: one glyph
  each, rasterized at the device size through the glyph cache, coloured by the style. An SDF
  draw type, like the live app's `examples/live/icon.zig`, for a few icons that animate, morph,
  or must stay crisp at any zoom; it costs a shader. No hinting either way, so a font icon at
  12 px is soft.

## Platform Hosts

### Native Linux (Wayland + wgpu-native)

GPU code links **wgpu-native v29.0.1.1**. The official Linux x86_64 release archive
is declared as a package dependency in `build.zig.zon`, downloaded automatically by
Zig's package manager, cached in `~/.cache/zig/p/`, and copied into the project's `zig-pkg/`
(gitignored). `addApp` installs the library into `<prefix>/lib` next to the executables.

The event loop in `src/host/linux_window.zig` (`Host(App)`) implements the libwayland
multi-thread reader protocol integrated with an optional Linux `timerfd`:
- `poll` descriptor set: six fixed slots, the Wayland display socket, `timer_fd`, the key
  repeat timerfd, the clipboard's send and receive pipes, and a producer's wake `eventfd`; an
  inactive slot is -1, which `poll` ignores. The repeat timer is armed only while a repeating key is held, and the pipes
  exist only during a transfer, so a focused idle text field sleeps.
  When `App.config.timer_period_ms == 0`, `timer_fd` is -1 (`no_timer_fd`), which `poll`
  ignores. The thread sleeps indefinitely while idle.
- When `timer_period_ms != 0`, the timer is created disarmed and `sync_timer` arms or
  disarms it before every sleep to match `cx.timer_on`; while armed it wakes the thread via
  `drain_timer` calling `App.timer(now_ms)`.
- An app with a producer gets that `eventfd`, attached to its `Wake` before `args`. Every wake
  calls `App.drain` (`sync_producer`) before the frame is scheduled, and the exit log line
  reports the wakes notified and the drains.
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
  are forwarded, and `wl_touch` fingers become contacts (see Touch). Keys go through libxkbcommon (the compositor's keymap, modifiers, and the
  locale's compose table for dead keys), and repeat follows `wl_keyboard.repeat_info` (25 Hz
  after 600 ms when the seat is too old to send it). Keyboard enter and leave are
  `window_focus`. The cursor is set with `wp_cursor_shape_v1` when the shape changes or the
  pointer enters; without that protocol the host logs once and leaves the cursor alone.
- Clipboard: `wl_data_device_manager` (version 3). A copy offers `text/plain;charset=utf-8`,
  `UTF8_STRING`, and `text/plain`; transfers run through non-blocking pipes in the poll set,
  a paste reads at most 64 KiB, and `SIGPIPE` is ignored. A stalled peer costs no wakes and
  is closed when the next copy or paste replaces it.
- File drops: the same data device's drag-and-drop events (see File Drops).
- Window chrome: `xdg_wm_base` is bound at `min(advertised, 5)`, so configure carries the
  tiled states and `wm_capabilities` the honoured requests; `zxdg_decoration_manager_v1` is
  bound when offered. The compositor's close is queued as `close_requested`, and after each
  dispatch the host sends the app's window request (see Window Chrome). The startup log names
  the decoration mode asked for and answered, and the window's capabilities.
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
- Touch: the canvas has `touch-action: none` and every finger takes pointer capture; events with
  `pointerType` `"touch"` call `wasm.touch_down`, `touch_move`, and `touch_up` with the DOM
  `pointerId` and `touch_cancel` on `pointercancel`, while pens stay on the mouse path (see Touch).
- Keyboard and clipboard: the canvas is focusable (`tabindex="0"`); `keydown` and `keyup`
  pass `event.key` as UTF-8 through the Wasm input buffer, and Zig names the key, so
  `shell.js` maps no keys. `preventDefault` runs only when Zig reports the key consumed
  (focus or Tab), never for Ctrl or Meta with C, X, or V, so the page's `copy`, `cut`, and
  `paste` events fire and use `clipboardData` synchronously. Canvas focus and blur are
  `window_focus`, the context menu is suppressed, all buttons are forwarded, and after each
  call `shell.js` sets `canvas.style.cursor` from `cursor()` and the CSS names Wasm exports.
  IME composition is not supported.
- File drops: `dragenter`, `dragover`, `dragleave`, and `drop` on the canvas, read with
  `File.slice` (see File Drops).
- `present_frame()` records a frame into a static `CommandBuffer` and calls `submit_js` once.
  JavaScript decodes the stream and its spans in place, with no intermediate copies, and
  asserts that `pass_begin` carries the canvas backing size.
- `?bench=1` times every render pass with `timestamp-query` when the adapter has it (see Bench
  Mode).
- A producer: the app's web module delivers its data and calls `shell.wake()`; `tick` calls
  `drain` before it animates and presents. Patchwork serves no audio worklet of its own.
