# Patchwork

A Zig 0.16.0 library that copies Makepad's drawing model: a retained widget
tree that lays itself out with a turtle and paints with instanced signed-distance
shaders. Step 1 opens one Wayland window and one full-page browser canvas,
clears each through a single WebGPU device and swapchain with FIFO present, and
blocks while the picture is clean.

## Native (Linux / Wayland)

GPU code links **wgpu-native v29.0.1.1**. The repo does not vendor the library
or invoke Cargo. Download the Linux x86_64 release from

https://github.com/gfx-rs/wgpu-native/releases/tag/v29.0.1.1

and unpack it so `libwgpu_native.so` sits in a directory of your choosing. The
hand-written binding matches that tag's `webgpu.h`.

```
zig build -Dwgpu-lib-dir=/path/to/wgpu-native/lib
zig build run -Dwgpu-lib-dir=/path/to/wgpu-native/lib
```

`zig build` and `zig build run` require that flag. After the window shows the
clear color, the process should sit in a sleeping poll (`ps -o state,wchan -p
<pid>`). Resize paints again. Closing the window exits.

## Tests, wasm, and the browser host

These steps do not link wgpu-native.

```
zig build test
zig build wasm
zig build serve
```

`zig build serve` starts a localhost static server for `index.html`, `shell.js`,
and the wasm module. WebGPU is unavailable on `file://`.
