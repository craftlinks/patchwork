# Patchwork

A Zig 0.16.0 library that copies Makepad's drawing model: a retained widget
tree that lays itself out with a turtle and paints with instanced signed-distance
shaders. Step 6 puts a panel, a button, and a slider on that buffer. Each widget
keeps its own state. Hover and press are animators: a float moving toward a
target. The native loop arms `wl_surface.frame` on every commit. A `done` with
nothing dirty arms nothing, so the process blocks in `poll` again. The browser
still presents inside `requestAnimationFrame`. The idle invariant is 0% CPU once
a `done` finds nothing dirty, including while the pointer rests on a widget.

Flow is downward only. Sizing is either `fixed: f32` or `fill`; content-derived `fit`
is deferred until text measurement and widgets exist. Padding lives on the `Column`
container, while `margin`, `width`, `height`, and `align_x` live on each child's `Walk`.
Column padding insets the inner rectangle where children walk. The turtle advances a
cursor along the main axis and writes border-box instance rectangles (margins excluded).
Children with `fill` height share leftover main-axis space equally. For fixed-width
children, `align_x` in `[0, 1]` positions the rectangle within positive horizontal slack;
oversized fixed dimensions are not clamped. If a child resolves to a non-positive edge,
it is still placed and still advances the cursor so siblings keep their positions, but
`scene.draw` omits it from the draw list to protect the GPU from degenerate quads.

The demo scene lays out a full-window column with 16px padding on all sides:
- Header panel: width `fill`, height `fixed 64`, zero margin, corner radius 8.
- Body panel: width `fill`, height `fill`, margin-top 16, corner radius 16.
  A button click cycles its fill through three colors.
- Slider: width `fill`, height `fixed 24`, margin-top 16. The value is absolute
  along the track. It starts at 0.5.
- Button: width `fixed 240`, height `fixed 48`, margin-top 16, `align_x = 1.0`,
  corner radius 24.
At 1280 x 720 the header is (16, 16, 1248, 64), the body is (16, 96, 1248, 504),
the slider is (16, 616, 1248, 24), and the button is (1024, 656, 240, 48).
Hover takes 100 ms and press takes 50 ms, independent of the display refresh.

Layout executes in two bounded passes with zero heap allocation (`child_cap = instance_cap - 1`,
allowing up to 255 child walks alongside the root column in the 256-instance draw list).
Window resize sets `Frame.relayout`, rebuilding the instance list. A display scale change
leaves `Frame.relayout` false, presenting the new physical framebuffer without re-walking
the column or bumping instance revisions.

Each panel is one instance of the same unit quad. The fragment shader evaluates a
rounded-box distance in local logical pixels, antialiases the edge from `fwidth`,
lightens the fill toward white by `hover`, then darkens that result toward black
by `down`. Radius 0 is a sharp rectangle. A radius of at least half the shorter
edge is a capsule, and a square with that radius is a disc. The instance record
is 48 bytes: rectangle, fill, and `(radius, hover, down, 0)`. The CPU hit test
uses that same field, so a rounded corner that shows the slate is not a hit.
The animator value is in `[0, 1]`. The instance stores `value * 0.18` for hover
and `value * 0.30` for down. The field derivation and the coverage math are in
`src/draw.zig` and `src/quad.wgsl`. The walk math is in `src/turtle.zig`. Widgets
are in `src/widgets.zig`. The scene and the pointer capture rules are in
`src/scene.zig`.

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
(`ps -o state,wchan -p <pid>`) and `top` shows 0% while the pointer rests, even
on the button. Moving onto the button fades the highlight in over about 100 ms.
Pressing darkens it. Dragging the slider moves the knob. Clicking the button
cycles the body color. A resize keeps hover on the widget that still contains
the pointer. The seat is bound at `wl_seat` version 1 and the client does not
call `set_cursor`; the compositor keeps the previous cursor image. Closing the
window exits.

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
layout. `requestAnimationFrame` runs during a fade or a resize, and it stops
once every animator has settled. A press dragged off the canvas releases,
because the canvas captures the pointer and a leave cancels the capture.
