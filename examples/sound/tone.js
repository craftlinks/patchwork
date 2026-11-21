// The web module of the audio and rack examples (Patchwork's `web/shell.js`, section 9a): the page
// plays Thrum's test tone in Thrum's own AudioWorklet, from the app's own wasm (`tone.zig`,
// section 4), through Thrum's `player` (`web/node.js`, served at `/thrum-node.js`).
//
// - `thrum_page_play(on)`, called by the wasm from Space's key handler, so the page has user
//   activation. The first start creates an `AudioContext` at 48 kHz, loads `/thrum-worklet.js`,
//   fetches `/patchwork.wasm`, and creates a two-channel `thrum` node with `monitor: true`, which
//   renders the tone from that wasm's `thrum_*` exports and posts every block it played. Later
//   calls resume or suspend the context, so a stopped tone's clock waits. Returns 1, or 0 in a
//   replay (`?bench=`), where the wasm stays on its offline engine and must not start sound.
// - Each monitor post is copied into the wasm's `thrum_page_inbox` and pushed with
//   `thrum_page_push`, then `shell.wake()` schedules the frame that drains it. `window.toneBlocks`
//   counts the blocks received, for a check.

import { player } from "/thrum-node.js";

const replaying = new URLSearchParams(window.location.search).has("bench");
window.toneBlocks = 0;

export function imports(shell) {
    return player({
        worklet_url: "/thrum-worklet.js",
        wasm_url: "/patchwork.wasm",
        channels: 2,
        refuse: replaying,
        instance: () => ({ exports: shell.wasm, memory: shell.memory }),
        on_blocks: (blocks) => {
            window.toneBlocks += blocks;
            shell.wake();
        },
    }).imports;
}
