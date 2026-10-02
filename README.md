# Patchwork

A Zig 0.16.0 library that copies Makepad's drawing model: a retained widget
tree that lays itself out with a turtle and paints with instanced signed-distance
shaders. Step 5 hit-tests that column. A pointer move or press picks the topmost
rounded face with the same distance field the shader paints, writes `hover` and
`down` onto the instance, and redraws. The process still blocks while the pointer
is resting.

Flow is downward only. Sizing is either `fixed: f32` or `fill`; content-derived `fit`
is deferred until text measurement and widgets exist. Padding lives on the `Column`
container, while `margin`, `width`, `height`, and `align_x` live on each child's `Walk`.
Column padding insets the inner rectangle where children walk. The turtle advances a
cursor along the main axis and writes border-box instance rectangles (margins excluded).
Children with `fill` height share leftover main-axis space equally. For fixed-width
children, `align_x` in `[0, 1]` positions the rectangle within positive horizontal slack;
oversized fixed dimensions are not clamped. If a child resolves to a non-positive edge,
it is still placed and still advances the cursor so siblings keep their positions, but
`paint_column` omits it from the draw list to protect the GPU from degenerate quads.

The demo scene lays out a full-window column with 16px padding on all sides, containing
three panels:
- Header: width `fill`, height `fixed 64`, zero margin, corner radius 8.
- Body: width `fill`, height `fill`, margin-top 16, corner radius 16.
- Footer: width `fixed 240`, height `fixed 48`, margin-top 16, `align_x = 1.0` (right-aligned),
  corner radius 24. Every panel starts at hover 0 and down 0.
At the default 1280 x 720 logical resolution, the root column rect is (0, 0, 1280, 720), the
header is (16, 16, 1248, 64), the body is (16, 96, 1248, 544), and the footer is
(1024, 656, 240, 48).

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
Hover is a weight of 0.18. Down is 0.30, and it follows the pointer while the
primary button is held. The field derivation and the coverage math are in
`src/draw.zig` and `src/quad.wgsl`. The walk math is in `src/turtle.zig`. The
hit test is in `src/hit.zig`.

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

After the window shows the padded column, the process sits in a sleeping poll
(`ps -o state,wchan -p <pid>`). Moving the pointer lightens the panel under it.
Pressing darkens that panel. A resize keeps the highlight on whatever face is now
under the last pointer position. The seat is bound at `wl_seat` version 1 and the
client does not call `set_cursor`; the compositor keeps the previous cursor image.
Closing the window exits.

## Tests, wasm, and the browser host

These steps do not link wgpu-native.

```
zig build test
zig build wasm
zig build serve
```

`zig build serve` starts a localhost static server for `index.html`, `shell.js`,
and the wasm module. WebGPU is unavailable on `file://`. The page shows the same
column. Pointer coordinates are multiplied by `devicePixelRatio` so they land in
the same space `resize` currently uses for layout. `requestAnimationFrame` runs
for a hit change or a resize, and it stays idle while the pointer moves inside
one panel. A press dragged off the canvas releases, because the canvas captures
the pointer.
