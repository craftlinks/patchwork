// AudioWorklet processor: runs the app's audio source from a second instance of its wasm.
//
// # Deep Architectural Guide for Reviewers:
//
// ## 1. Role
// The app declares its source in Zig (`src/app.zig`, section 4a), so the signal has one
// definition on both hosts. This processor holds no synthesis: `shell.js` passes the wasm's
// bytes in `processorOptions.wasm`, the constructor compiles them synchronously (allowed off
// the main thread) and instantiates them with every import a no-op, then calls
// `audio_init(sampleRate)`. That instance never calls `start`, so only the source's own static
// storage is used (`src/host/web_exports.zig`, section 4b).
//
// ## 2. One Quantum
// `process` calls `audio_render()`, which renders one 128-frame interleaved stereo block and
// returns its address, de-interleaves it into the two output channels (so the source is
// audible), and appends it to the post buffer. Every `audio_post_blocks()` quanta the buffer is
// posted to the main thread, transferred rather than copied, and a new one is allocated. The
// processor returns true, so it lives as long as its node; `shell.js` suspends the context to
// stop it.

class PatchworkAudio extends AudioWorkletProcessor {
    constructor(options) {
        super();
        const module = new WebAssembly.Module(options.processorOptions.wasm);
        const instance = new WebAssembly.Instance(module, stubs_of(module));
        this.wasm = instance.exports;
        this.wasm.audio_init(sampleRate);
        this.postBlocks = this.wasm.audio_post_blocks();
        this.blockSamples = 128 * 2;
        this.filled = 0;
        this.buffer = new Float32Array(this.postBlocks * this.blockSamples);
    }

    process(inputs, outputs) {
        const output = outputs[0];
        const pointer = this.wasm.audio_render();
        const block = new Float32Array(this.wasm.memory.buffer, pointer, this.blockSamples);
        const frames = Math.min(output[0].length, 128);
        for (let index = 0; index < frames; index += 1) {
            output[0][index] = block[index * 2];
            if (output.length > 1) {
                output[1][index] = block[index * 2 + 1];
            }
        }
        this.buffer.set(block, this.filled * this.blockSamples);
        this.filled += 1;
        if (this.filled === this.postBlocks) {
            this.port.postMessage(this.buffer, [this.buffer.buffer]);
            this.buffer = new Float32Array(this.postBlocks * this.blockSamples);
            this.filled = 0;
        }
        return true;
    }
}

// A no-op returning 0 for every function the wasm imports: this instance only renders, and an
// app with a web module imports functions of its own beside `submit_js` (`web/shell.js`, 9a).
function stubs_of(module) {
    const imports = {};
    for (const entry of WebAssembly.Module.imports(module)) {
        if (entry.kind === "function") {
            imports[entry.module] ??= {};
            imports[entry.module][entry.name] = () => 0;
        }
    }
    return imports;
}

registerProcessor("patchwork-audio", PatchworkAudio);
