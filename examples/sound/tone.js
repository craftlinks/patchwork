// The web module of the audio and rack examples (Patchwork's `web/shell.js`, section 9a): the page
// plays Thrum's test tone in Thrum's own AudioWorklet, from the app's own wasm (`tone.zig`,
// section 4).
//
// - `tone_run(on)`, called by the wasm from Space's key handler, so the page has user activation.
//   The first start creates an `AudioContext` at 48 kHz, loads `/thrum-worklet.js`, fetches
//   `/patchwork.wasm`, and creates a `thrum` node with `monitor: true`, which renders the tone from
//   that wasm's `thrum_*` exports and posts every block it played. Later calls resume or suspend
//   the context, so a stopped tone's clock waits, as Patchwork's own worklet did. Returns 1, or 0
//   in a replay (`?bench=`), where the wasm stays on its offline engine and must not start sound.
// - Each monitor post is copied into the wasm's `tone_inbox` and pushed with `tone_push`, then
//   `shell.wake()` schedules the frame that drains it. `window.toneBlocks` counts the blocks
//   received, for a check.

const sample_rate_hz = 48000;
const replaying = new URLSearchParams(window.location.search).has("bench");
let context = null;
window.toneBlocks = 0;

async function sound_start(shell, created) {
    const [, wasm] = await Promise.all([
        created.audioWorklet.addModule("/thrum-worklet.js"),
        fetch("/patchwork.wasm").then((response) => response.arrayBuffer()),
    ]);
    const node = new AudioWorkletNode(created, "thrum", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2],
        processorOptions: { wasm, monitor: true },
    });
    node.port.onmessage = (event) => {
        const { monitor, blocks, failed } = event.data;
        if (failed !== undefined) {
            console.error(`tone: the worklet failed: ${failed}`);
            return;
        }
        if (monitor === undefined) {
            return;
        }
        const address = shell.wasm.tone_inbox();
        const inbox = new Float32Array(shell.memory.buffer, address, monitor.length);
        inbox.set(monitor);
        shell.wasm.tone_push(blocks);
        window.toneBlocks += blocks;
        shell.wake();
    };
    node.connect(created.destination);
}

export function imports(shell) {
    return {
        tone_run(on) {
            if (replaying) {
                return 0;
            }
            if (context === null) {
                context = new AudioContext({ sampleRate: sample_rate_hz, latencyHint: "interactive" });
                context.resume();
                sound_start(shell, context).catch((error) => console.error(`tone: ${error.message}`));
            } else if (on === 1) {
                context.resume();
            } else {
                context.suspend();
            }
            return 1;
        },
    };
}
