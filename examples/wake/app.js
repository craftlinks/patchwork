// The wake example's web module (`web/shell.js`, section 9a): the browser's producer.
//
// The wasm calls `wake_run(on)` when Space starts or stops it (`examples/wake/app.zig`, section
// 2). While running, an interval of 5 ms calls the wasm's own export `wake_push`, which steps the
// producer by one tick and pushes it into the app's ring, and then `shell.wake()`, which schedules
// one frame whose `tick` drains the ring. A replay (`?bench=`) steps the producer itself, frame
// by frame, so the interval never starts there and the page matches the headless frame.

const tick_ms = 5;
const replaying = new URLSearchParams(window.location.search).has("bench");
let interval = 0;

export function imports(shell) {
    return {
        wake_run(on) {
            if (replaying) {
                return;
            }
            if (on === 1 && interval === 0) {
                interval = setInterval(() => {
                    shell.wasm.wake_push();
                    shell.wake();
                }, tick_ms);
            } else if (on === 0 && interval !== 0) {
                clearInterval(interval);
                interval = 0;
            }
        },
    };
}
