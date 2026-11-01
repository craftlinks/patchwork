# Patchwork

A Zig UI library after Makepad's drawing model. Widgets are plain structs that lay themselves
out with a turtle while they draw, record hit areas as they go, and paint with instanced
signed-distance shaders. No dynamic dispatch, no vtables, no allocation after startup.

One app file compiles to a native Linux executable (Wayland + wgpu-native) and to
`wasm32-freestanding` for the browser (WebGPU).

## Requirements

| | |
|---|---|
| Zig | **0.17.0** exactly (`minimum_zig_version`). Older distro packages will not build it. |
| OS | x86_64 Linux on a **Wayland** session. No X11 host, no Windows, no macOS, no aarch64. |
| GPU | A Vulkan driver (wgpu-native runs on it). |
| Build tools | `pkg-config`, plus the **development** packages of `libwayland-client` and `libxkbcommon`. |
| Network | First build only: Zig fetches `wgpu-native` (a pinned release, hash-checked). |

Typical package names for the build tools:

```bash
sudo pacman -S pkgconf wayland libxkbcommon                  # Arch
sudo apt install pkg-config libwayland-dev libxkbcommon-dev  # Debian, Ubuntu
sudo dnf install pkgconf wayland-devel libxkbcommon-devel    # Fedora
```

The browser build needs only Zig and a browser with WebGPU.

## Try It

```bash
git clone <repo-url> patchwork && cd patchwork
zig build run                 # the synthesizer rack, natively
zig build serve               # the same app in the browser; prints the address
zig build run-gallery         # every widget on one screen
```

Every example has `run-<name>`, `wasm-<name>` and `serve-<name>` steps:

| Example | Shows |
|---|---|
| `rack` | Synthesizer rack: knobs, meters, toggles, a timer |
| `column` | One scrolling view of mixed controls |
| `live` | Code editor with syntax colors |
| `session` | Live-coding screen, rebuilt from photos with the public API only |
| `vector` | Filled shapes on the GPU: stars, a ring, a glyph outline, a morph; text as outlines |
| `touch` | Multi-touch: ten fingers on pads and sliders, a pinch box |
| `data`, `wave`, `fx` | Data textures; waveforms and spectra; offscreen effects |
| `audio` | Audio meters and scope (silent natively, audible in the browser) |
| `canvas` | Pan and zoom canvas |
| `gallery`, `workspace` | Widget gallery; docking workspace |

Smaller binaries: add `-Doptimize=ReleaseSmall` (the `session` executable drops from 103 MB
to 0.6 MB). A shipped app is the executable plus `lib/libwgpu_native.so`; keep `bin/` and
`lib/` side by side.

## An App

An app is one file declaring `pub const App`, which satisfies the contract in
[src/app.zig](src/app.zig):

```zig
pub const App = struct {
    pub const config: patchwork.app.Config = .{
        .title = "Hello",
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

The smallest complete example to copy from is
[examples/column/app.zig](examples/column/app.zig).

To use Patchwork from your own project, add it to `build.zig.zon` and call
`patchwork.addApp(b, dep.builder, .{ .name, .root_source_file, .target, .optimize })` in your
`build.zig`. It returns the `run`, `wasm`, `serve`, `bench`, `tests` and `install` steps. The
full snippet is in [docs/reference.md](docs/reference.md#use-patchwork-from-another-project).

## Commands

```bash
zig build test                  # unit tests: library and all examples (no GPU needed)
zig build test-contract         # the app contract rejects malformed apps at compile time
zig build check                 # compile every shader and pipeline headless (needs a GPU)
zig build regress -Doptimize=ReleaseFast   # headless frame hashes against test/golden (GPU)
zig build bench-live -Doptimize=ReleaseFast -- typing-stress --adapter low
./zig-out/bin/fx --render scope --size 1920x1080 --scale 2 --out -   # raw RGBA for ffmpeg
```

Native flags: `<app> [--adapter low|high] [--no-cache] [--check] [--decorations client|server]`.
`-Dwgpu-lib-dir=<dir>` links a local `wgpu-native` build instead of the fetched one.

## Layout

```text
src/            library: draw, ui, widgets, text, editor, gpu
src/host/       platform hosts: Wayland + wgpu-native (native_main), browser (web_main)
web/            browser shell: shell.js, worklet.js, index.html
examples/       twelve apps
test/golden/    frame hashes per adapter
tools/          frame comparison, font subsetting
docs/           reference manual
```

## Dependencies

No Zig packages beyond `wgpu-native`. The native build links `libwayland-client`,
`libxkbcommon`, libc and `libwgpu_native.so` dynamically; the browser build links nothing.
Everything else is Zig.

## Documentation

- [docs/reference.md](docs/reference.md): the full manual covering the app contract, layout,
  widgets, theming, drawing, text, audio, platform hosts, benchmarks, regression and
  rendering frames.
