# Patchwork

A Zig 0.16.0 library that copies Makepad's drawing model: a retained widget
tree that lays itself out with a turtle and paints with instanced signed-distance
shaders. The demo scene stores a modular synthesizer rack of three panels:
Oscillator (`osc`), Filter (`filter`), and Amplifier (`amp`). Each panel contains
four continuous rotary knobs and a passive vertical level meter driven by the host
clock. Each widget keeps its own state. Hover transitions are animators: a float
moving toward a target over 100 ms. Text labels and level meters are not animators,
so they do not keep continuous frame callbacks alive. The native loop sleeps in
`ppoll` and wakes about 30 times a second for the meter timer, plus Wayland events
and the present latch. The browser host presentation uses `requestAnimationFrame`
triggered on demand by pointer input or the host meter interval (~30 Hz). Hover
animators still do not chain their own loop once settled.

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
`scene.draw` omits it from the draw list to protect the GPU from degenerate quads.

The demo scene (`Scene.init_demo`) lays out a modular rack of three panels in a
full-window column with 16 px outer padding:
- Panels: `osc`, `filter`, and `amp`.
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
- Procedural meter levels (`src/levels.zig`): triangle waves with integer periods and phase
  offsets: `osc` (2000 ms, phase 500 ms), `filter` (3000 ms, phase 750 ms), `amp` (4000 ms,
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
- `Panel`, `Button`, `Slider`, and `Scroll` remain fully implemented and tested in the codebase.
  `Scene.init_column` and `Scene.layout_column` build the retained scroll-column scene from
  Step 8 so existing scroll tests keep their regression locks.

Knobs render two `kind_arc` faces on a 56 x 56 ring: a dark track using `theme.track`
(sweep fraction 1.0) and an active value arc using a colorful accent. The active arc is
omitted when value is 0.0. Dragging vertically adjusts value by `-dy / 120.0` (dragging up
increases value). Mouse wheel over a visible knob ring nudges that knob by `-dy / 120.0`
without scrolling. Knob accents are per-instance fills, not theme slots. The meter is a passive
12 x 144 column with an upward-growing fill; `Meter.set_value` returns false when unchanged, and
drawing only reads `value`.

As a library container, `Scroll` owns `[16]Control` (`src/widgets.zig`). The scene captures the
scroll container, and the scroll arbitrates `press`: `.none`, `.child(i)`, or `.thumb`. Stored
child rects are unscrolled; drawing and hit testing subtract `scroll_y`. Non-overlapping children
are culled from draw lists. Partially visible straddlers carry the viewport clip rect. The scrollbar
thumb height is `max(24, viewport_h * viewport_h / content_h)` (hidden when `max_scroll == 0`),
and thumb drag maps absolute pointer travel to `[0, max_scroll]`. Wheel elsewhere in the
viewport scrolls the content column by adding `dy` to `scroll_y`. Horizontal wheel is ignored.

Both `Instance` and `Glyph` records are 64 bytes (`instance_stride = 64`, `glyph_stride = 64`).
The instance buffer is 256 * 64 = 16,384 bytes, and the glyph buffer is 256 * 64 = 16,384 bytes.
The static unit quad vertex buffer remains **48 bytes** (6 vertices * 2 floats * 4 bytes).
In both instance formats, the fourth `float32x4` attribute at byte offset 48 (shader location 4)
is the exclusive-max clip rectangle `(clip_x0, clip_y0, clip_x1, clip_y1)`. `kind` selects the
primitive (`kind_box = 0`, `kind_arc = 1`). Shaders evaluate an analytic hard clip mask:
`pos = rect.xy + local`
`inside = step(clip.x, pos.x) * step(clip.y, pos.y) * step(pos.x, clip.z) * step(pos.y, clip.w)`
`alpha = fill.a * coverage * inside`
There is no unclipped sentinel: chrome and panel faces use the window rect, while panel
children (knobs and meters) use the panel border box clip.

The 256-byte uniform buffer stores the 64-byte 4x4 matrix at offset 0 followed by a 192-byte
`Theme` record at offset 64 (`src/theme.zig`). `Theme` holds 12 `vec4` slots: panel, text,
track, value, control, meter, lighten (white), darken (black), arc angles, and 3 zero pads.
`arc.x` is start angle `2pi/3` (7 o'clock); `arc.y` is sweep `3pi/2` (270 degrees). `quad.wgsl`
branches on `kind` (box vs arc), mixes toward theme lighten/darken, reads arc angles from the
uniform (no WGSL color or angle literals), and applies the clip mask. `glyph.wgsl` shares the
same 256-byte Frame uniform view and applies the same clip mask.

Layout executes in two bounded passes with zero heap allocation (`child_cap = instance_cap - 1`,
allowing up to 255 child walks alongside the root column in the 256-instance draw list).
Window resize sets `Frame.relayout`, rebuilding the instance list. A display scale change
leaves `Frame.relayout` false, presenting the new physical framebuffer without re-walking
the column or bumping instance revisions.

## Native (Linux / Wayland)

GPU code links **wgpu-native v29.0.1.1**. The official Linux x86_64 release archive
is declared as a package dependency in `build.zig.zon`, downloaded automatically by
Zig's package manager, and permanently cached in `~/.cache/zig/p/`.

```
zig build
zig build run
```

An optional override flag `-Dwgpu-lib-dir=` is available if you wish to link against
a custom unpack directory or local build:

```
zig build run -Dwgpu-lib-dir=/path/to/wgpu-native/lib
```

Use the distro `zig` (`/usr/bin/zig` on this machine). The official 0.16.0
tarball's LLD rejects GCC 16's `.sframe` relocations in `crt1.o`.

After the window shows the rack, the thread sleeps in `ppoll` and wakes about 30 times a
second for the meter timer, plus Wayland events and the present latch. Hover animators still
do not chain their own loop. Steady state is one present per timer wake, then sleep in `ppoll`.
This is not a spin, and it is not 0% CPU. Moving onto a knob fades its active arc highlight
in over 100 ms. Dragging upward increases the value. Scrolling with the wheel over a knob ring
nudges its value. A resize keeps hover on the widget that still contains the pointer. The seat
is bound at `wl_seat` version 1 and the client does not call `set_cursor`; the compositor
keeps the previous cursor image. Closing the window exits.

Frame pacing during a drag: each commit requests `wl_surface.frame` and
`wp_presentation.feedback`. The `presented` event is the pageflip time and the
output's refresh period; the next commit is scheduled 3 ms before the vblank
projected from it, and that commit draws the pointer sample that has arrived.
Without
`wp_presentation` the `done` receipt is the anchor instead. The swapchain uses
mailbox when the surface offers it: the loop already commits once per `done`,
and Mesa's FIFO path on Wayland (`wp_fifo_v1`, two commits per present) was
delaying every other frame callback by a refresh, which showed as a two-frame
hole after every second frame. Measured on Hyprland 0.56 at 60 Hz, a commit
reaches the screen about 2.6 ms after it is sent, and 348 of 377 presents in a
continuous hover sweep were one refresh apart. The details and the numbers are
in `src/linux_window.zig`, `src/gpu_wgpu.zig`, and `src/wp_presentation.zig`.

## Tests, wasm, and the browser host

These steps do not link wgpu-native.

```
zig build test
zig build wasm
zig build serve
```

`zig build serve` starts a localhost static server for `index.html`, `shell.js`,
and the wasm module. WebGPU is unavailable on `file://`. The page shows the same
rack. `shell.js` calls `arm_meter_clock()`, running a `setInterval` at
`meter_period_ms()` (33 ms) calling `wasm.meter_clock()`. When a meter value changes,
`meter_clock` returns 1 and schedules a single `requestAnimationFrame`. The interval is
never cleared. `tick()` still returns 1 only while an animator is moving, so a resting
pointer does not chain frames. Pointer coordinates, including press and release, are
multiplied by `devicePixelRatio` so they land in the same space `resize` currently uses
for layout. Wheel events are forwarded via `pointer_wheel` with line and pixel normalization.
A press dragged off the canvas releases, because the canvas captures the pointer and a
leave cancels the capture.
