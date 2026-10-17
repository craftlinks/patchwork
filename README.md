# Patchwork

A Zig 0.16.0 library that copies Makepad's drawing model: a retained widget
tree that lays itself out with a turtle and paints with instanced signed-distance
shaders. The demo scene stores a single right-hand `Scroll` container hosting an
inspector column of knobs, a meter, and toggles. Each widget keeps its own state.
Hover and toggle transitions are animators: a float moving toward a target over
100 ms. Text is not an animator, so labels do not keep frame callbacks alive.
The native loop arms `wl_surface.frame` on every commit. A `done` with nothing dirty
arms nothing, so the process blocks in `poll` again. The browser host presents inside
`requestAnimationFrame`. The idle invariant is 0% CPU once a `done` finds nothing dirty,
including while the pointer rests on a control and while all labels are on screen.

Flow is downward only. Sizing is `fixed`, `fill`, or `fit`. Padding lives on the
container, while `margin`, `width`, `height`, and `align_x` live on each child's `Walk`.
Container padding insets the inner rectangle where children walk. The turtle advances a
cursor along the main axis and writes border-box instance rectangles (margins excluded).
Children with `fill` height share leftover main-axis space equally. For fixed-width
children, `align_x` in `[0, 1]` positions the rectangle within positive horizontal slack;
oversized fixed dimensions are not clamped. If a child resolves to a non-positive edge,
it is still placed and still advances the cursor so siblings keep their positions, but
`scene.draw` omits it from the draw list to protect the GPU from degenerate quads.

The demo scene lays out a single `Scroll` widget pinned to the right edge within a
full-window column with 16 px outer padding:
- Column walk: width `fixed 320`, height `fill`, `align_x = 1.0`, margin zero.
- At 1280 x 720: border box is (944, 16, 320, 688).
- At 800 x 600: border box is (464, 16, 320, 568).
- Scroll internal padding is 8 px on all sides.
- Viewport at 1280 x 720: (952, 24, 304, 672).
- Content column (inset by 16 px scrollbar gutter): (952, 24, 288, 672).
- Eleven children with `margin.top = 8` and `width = .fill`:
  - Eight Knobs: height `fixed 72`. Names: `gain`, `slope`, `twice`, `skew`, `echo`,
    `room`, `out`, `drive`. Initial values: 0.25, 0.50, 0.75, 0.00, 1.00, 0.50, 0.50, 0.50.
  - One Meter: height `fixed 160`. Name: `meter`. Initial value: 0.50.
  - Two Toggles: height `fixed 40`. Names: `take` (starts on), `drums` (starts off).
- Total content span is 904 px (`8 * 80 + 1 * 168 + 2 * 48 = 640 + 168 + 96 = 904`).
- Maximum scroll offset `max_scroll` is 232 at 1280 x 720 and 352 at 800 x 600.
- `Panel`, `Button`, and `Slider` remain fully implemented and tested in `src/widgets.zig`,
  though they are not included in the current demo scene.

Knobs render two `kind_arc` faces on a 56 x 56 ring: a dark track using `theme.track`
(sweep fraction 1.0) and an active value arc using a colorful accent. The active arc is
omitted when value is 0.0. Dragging vertically adjusts value by `-dy / 120.0` (dragging up
increases value). Mouse wheel over a visible knob ring nudges that knob by `-dy / 120.0`
without scrolling. As a demo choice, knob accents cycle across four colors by knob index:
purple `(0.62, 0.45, 0.86)`, green `(0.40, 0.78, 0.48)`, orange `(0.93, 0.55, 0.24)`,
and yellow `(0.93, 0.80, 0.32)`. Knob accents are per-instance fills, not theme slots.
The meter is a passive 12 x 144 column with an upward-growing fill. Toggles are 44 x 24
capsules whose thumb aims over 100 ms when released inside the pill.

`Scroll` owns `[16]Control`. The scene captures the scroll container, and the scroll
arbitrates `press`: `.none`, `.child(i)`, or `.thumb`. Stored child rects are unscrolled;
drawing and hit testing subtract `scroll_y`. Non-overlapping children are culled from draw
lists. Partially visible straddlers carry the viewport clip rect. The scrollbar thumb
height is `max(24, viewport_h * viewport_h / content_h)` (hidden when `max_scroll == 0`),
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
There is no unclipped sentinel: chrome uses the window rect, and scroll content
uses the viewport clip.

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

After the window shows the column, the process sits in a sleeping poll
(`ps -o state,wchan -p <pid>`) and `top` shows 0% while the pointer rests.
Moving onto a knob fades its active arc highlight in over 100 ms. Dragging
upward increases the value. Scrolling with the wheel over a knob ring nudges its
value. Scrolling elsewhere scrolls the column. Clicking a toggle flips its switch.
A resize keeps hover on the widget that still contains the pointer. The seat is
bound at `wl_seat` version 1 and the client does not call `set_cursor`; the
compositor keeps the previous cursor image. Closing the window exits.

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
column. Pointer coordinates, including press and release, are multiplied by
`devicePixelRatio` so they land in the same space `resize` currently uses for
layout. Wheel events are forwarded via `pointer_wheel` with line and pixel
normalization. `requestAnimationFrame` runs during a fade or a resize, and it stops
once every animator has settled. A press dragged off the canvas releases,
because the canvas captures the pointer and a leave cancels the capture.
