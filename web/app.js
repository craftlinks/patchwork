// The app's web module when it brings none: Patchwork's shell imports `/app.js` from every page
// (`web/shell.js`, section 9a), and this one adds no imports and starts nothing. An app that
// needs its own code in the page, a worklet of a peer library or a worker, passes
// `AppOptions.web_module`, which `serve` then serves here instead (`build.zig`).
