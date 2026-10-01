# Patchwork

A Zig 0.16.0 library that copies Makepad's drawing model: a retained widget
tree that lays itself out with a turtle and paints with instanced signed-distance
shaders. Step 3 draws seven SDF box faces in one instanced call on a
Wayland window and a full-page browser canvas, then blocks while the picture is clean.

Each face is one instance of the same unit quad. The fragment shader evaluates a
rounded-box distance in local logical pixels, antialiases the edge from `fwidth`,
and lightens the fill toward white by a baked hover weight. Radius 0 is a sharp
rectangle. A radius of at least half the shorter edge is a capsule, and a square
with that radius is a disc. The instance record is 48 bytes: rectangle, fill, and
`(radius, hover, 0, 0)`. The field derivation and the coverage math are in
`src/draw.zig` and `src/quad.wgsl`.

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

After the window shows the slate plus seven SDF box faces (sharp, rounded, pill,
three hover steps, and one translucent rect), the process sits in a sleeping poll
(`ps -o state,wchan -p <pid>`). Resize paints again. Closing the window exits.

## Tests, wasm, and the browser host

These steps do not link wgpu-native.

```
zig build test
zig build wasm
zig build serve
```

`zig build serve` starts a localhost static server for `index.html`, `shell.js`,
and the wasm module. WebGPU is unavailable on `file://`. The page shows the same
seven SDF box faces. The frame scheduler is idle after the first paint
and wakes once on resize.
