# Patchwork

A Zig 0.16.0 library that copies Makepad's drawing model: a retained widget
tree that lays itself out with a turtle and paints with instanced signed-distance
shaders. Step 4 walks a column of panels inside the logical window and paints
them in one instanced call on a Wayland window and a full-page browser canvas,
then blocks while the picture is clean.

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
  corner radius 24, hover weight 1.0.
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
and lightens the fill toward white by a baked hover weight. Radius 0 is a sharp
rectangle. A radius of at least half the shorter edge is a capsule, and a square
with that radius is a disc. The instance record is 48 bytes: rectangle, fill, and
`(radius, hover, 0, 0)`. The field derivation and the coverage math are in
`src/draw.zig` and `src/quad.wgsl`. The walk math is in `src/turtle.zig`.

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

After the window shows the padded column (header, expanding body, and right-aligned hover-1
footer), the process sits in a sleeping poll (`ps -o state,wchan -p <pid>`). Resize lays the
column out again and paints. Closing the window exits.

## Tests, wasm, and the browser host

These steps do not link wgpu-native.

```
zig build test
zig build wasm
zig build serve
```

`zig build serve` starts a localhost static server for `index.html`, `shell.js`,
and the wasm module. WebGPU is unavailable on `file://`. The page shows the same
column. The frame scheduler is idle after the first paint and wakes once on resize.
