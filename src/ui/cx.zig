//! The UI context: the draw context plus the turtle stack, the hit areas, and pointer state.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why One Context
//! Layout happens while drawing (Makepad's turtle): `begin` opens a container, the children
//! walk and append instances, and `end` resolves fit sizes and alignment. Widgets record hit
//! areas while they draw, and the next events resolve against those areas. All of that state
//! is per frame and per window, so it lives beside the draw pools in one value,
//! `Context(Draw, area_cap)`, which embeds the draw context by value as `cx.draw`. The host
//! keeps one static instance; the renderer reads `&cx.draw`.
//!
//! ## 2. Phases
//! ```text
//! idle  --event_begin-->  event  --event_end-->  idle      ui.dispatch, once per event
//! idle  --begin_frame-->  draw   --end_frame-->  idle      ui.draw_frame, when owed
//! ```
//! `append`, `drawing`, `walk`, `begin`, and `area` assert the draw phase; `hit`, the focus
//! changes, `copy`, and `request_paste` assert the event phase; `redraw` asserts that no draw
//! is running, because a draw reads the state it would mark dirty.
//!
//! ## 3. Turtles and Clips
//! `begin_frame` pushes the root turtle: the window, flowing down, clipped to the window.
//! Each entry records the pool counts (`draw.counts`) and the area count when it opened. A
//! `Layout.clip` container intersects the clip with its border box; an empty intersection
//! is `null`, and widgets draw nothing under it (`visible`). Every instance and area copies
//! the clip in effect when it was made.
//!
//! ## 3a. Canvases
//! `begin_canvas(id, walk, layout, *CanvasState, layers)` opens a pan/zoom canvas
//! (`ui/canvas.zig`). It records the canvas's own wheel area over the viewport in screen pixels,
//! gives each of `layers` the state's view this frame (`draw.Context.view`), and switches to
//! the first. Inside, until `end_canvas`, everything is in world pixels:
//! ```text
//! clip     T^-1(parent clip ∩ viewport):  x0' = (x0 - view.x) / zoom, likewise each edge
//! turtle   a root over T^-1(viewport), the visible world rect (`remaining`)
//! visible  the usual cull test, against the world clip
//! area     mapped forward: rect' = (view.x + zoom * x, view.y + zoom * y, zoom * w,
//!          zoom * h), radius' = zoom * radius, clip' = T(world clip), Area.zoom = zoom
//! shift    snapped to 1 / text.device_scale(); areas move by delta * zoom
//! ```
//! Instances keep world rects and clips, which the renderer draws through the layer's view;
//! areas are on the screen, so resolution, capture, and `Press.rect` need no inverse. The glyph
//! zoom (`text.zoom`) is the rung nearest the zoom while the canvas is open and 1 after.
//! Canvases do not nest.
//!
//! ## 3b. Free Placement
//! `begin_at(rect, layout)` opens a container at a fixed `rect` in the current coordinates
//! without placing it in its parent's flow, so a canvas places modules at their world rects.
//! Its `end` aligns its children as usual but neither shifts it nor advances the parent.
//!
//! ## 3c. Popups
//! A popup (a menu, a dropdown's list, a dialog) is drawn by its owner at the end of
//! `App.draw` (`ui.overlays`), when only the root is open. `begin_popup(id, rect, layout, dim)`
//! switches to `Layer.popup`, appends a black face over the window at alpha `dim` (0 for none,
//! a dialog's dimming otherwise), records the backdrop area `popup_backdrop(id)` over the whole
//! window, and opens a free container (section 3b) at `rect` under the window clip, so nothing
//! the app opened clips it; `end_popup` closes it and restores the layer. Resolution prefers
//! the highest layer and then the last appended (`ui/areas.zig`, section 4), so the popup's own
//! areas, recorded after the backdrop, take the pointer over them, and the backdrop takes it
//! everywhere else: a press outside reaches no base widget, so it only dismisses. One popup per
//! frame (`popup.popup_depth_max`), never inside a canvas, and never while the popup layer is
//! bound offscreen (asserted).
//!
//! A widget that opens a popup calls `request_popup(id)`, which owes a draw. The owner's draw
//! then meets the request with `begin_popup` (or `skip_popup` when its anchor was not drawn),
//! and in safe builds `end_frame` panics naming the id when nothing met it: an app that forgot
//! `ui.overlays` learns it on the first open, not by a menu that never shows.
//!
//! ## 4. Alignment After the Fact
//! At `end`, `turtle.main_shift` (main-axis alignment of the children) and then
//! `turtle.self_shift` (a fit container's own cross alignment) each give one delta. The delta
//! is snapped to the device grid, `d = round(d * s) / s` with `s = scale_120 / 120`, so the
//! glyphs `text.place` snapped stay on device pixels, and is then added to `rect.xy` of every
//! instance appended since the entry opened (`draw.shift`) and of every area recorded since.
//! A zero delta does nothing. Clips never move, so a container that shifts by a non-zero
//! delta must not contain a clipping container (asserted with the running `clip_total`), and
//! a clipping container must have a non-fit size on both axes.
//!
//! ## 5. Hit Resolution
//! `event_begin` stores the pointer and resolves the hot area and the wheel target once
//! (`areas.resolve`, O(areas)); `hit(id, event)` is then O(1) per widget:
//! ```text
//! move        captured: the capture gets drag; else hover_in / hover_out from the old to
//!             the new hover (the hot id)
//! left down   the hot area gets down and becomes the capture; the old hover gets hover_out
//! left up     the capture gets up { inside = hot is the capture }; a new hot id gets hover_in
//! right down  uncaptured: the hot area gets secondary (no capture); otherwise as move
//! other       a middle press and every non-left release act as a move
//! leave       the capture gets up { inside = false }; else the hover gets hover_out
//! wheel       the wheel target gets wheel; otherwise as move
//! keys, paste, window focus, frame: none (section 7)
//! drops       none: file drags answer through `drop_hit` (section 7a)
//! ```
//! A path area (`path_area`, for a stroke drawn with `draw.path`) is hit within a distance of
//! its polyline instead of a rounded rect (`ui/areas.zig`, section 3); the scan is the same.
//! While a capture is held, hover is frozen on it. `down`, `drag`, and `secondary` carry the
//! area's rect (`Press.rect`) from the last draw, so widgets keep no rects of their own, and
//! the press count of the click sequence (`Press.clicks`, `input.count_click`). Only the left
//! button captures, so a right release never ends a left drag.
//!
//! ## 5a. The Window
//! An area whose `Flags.window` is not `none` stands for a part of the window (`ui/areas.zig`,
//! section 3), and a press on it is a request to the window manager, not a widget's press:
//! ```text
//! left down on drag, a double press   toggle_maximize
//! left down on drag                   move { the press's serial }
//! left down on an edge                resize { edge, serial }
//! right down on drag                  menu { x, y, serial } (the window manager's menu)
//! ```
//! A window area never captures: the window manager takes the pointer, and the release may
//! never come. Focus is cleared, as for any unfocusable press. The app asks with `minimize`,
//! `toggle_maximize`, and `close`; the last request of a dispatch wins. `close_requested`
//! sets `close` before the app sees it, and `keep_open` during that event cancels it, so an
//! app that ignores the event closes. The host takes the request after each dispatch
//! (`take_window_request`): natively it becomes an `xdg_toplevel` request, and in the browser
//! it is dropped; a bench run simulates it (`bench.serve_window`). `window_state` events store
//! the window's state, which `window_state()` reports in any phase, and owe a draw.
//!
//! ## 5b. Touch
//! A finger is a contact: `touch_down` claims one of `input.contact_cap` slots, which holds its
//! own pointer state (`PointerSlot`: pointer, hot, hover, capture, the press flags). The mouse's
//! state is the context's own fields, and a contact's is swapped in for the dispatch of its
//! events, so while a finger's event runs `self.capture` is that finger's and between dispatches
//! it is the mouse's. `ui.dispatch` turns a touch event into the pointer events widgets already
//! read, so `hit` and every widget work under each finger unchanged:
//! ```text
//! touch_down    pointer_down (left, the contact's serial)
//! touch_move    pointer_move
//! touch_up      pointer_up, then pointer_leave (the leave ends hover, as a bench click does)
//! touch_cancel  pointer_leave: the capture gets up { inside = false }, so no click
//! ```
//! - **Primary.** A contact is primary when it lands with no other contact live (the Pointer
//!   Events rule). Only it moves focus, presses a window area, and begins a drag between widgets.
//! - **Joined.** A press on an area the mouse or another contact holds does not capture it: the
//!   contact's `capture` stays `.none`, `hot` and `hover` are cleared, so widgets answer `none`,
//!   and `target` records the area for `touch()`. `Flags.primary_only` makes the area absent to
//!   any contact but the primary (`target` is then `.none`).
//! - **Hover** of a finger is what it pressed, down to its lift: a finger that holds nothing
//!   resolves nothing on a move.
//! - **Clicks** of fingers share `touch_clicks` with `input.touch_click_slop_px`, so a double
//!   tap, two contacts, counts 2.
//! - **Safety.** A `touch_down` of an id still live first cancels that contact (a lost up
//!   cannot outlast the next press); a contact over `contact_cap` is counted in
//!   `contacts_refused` and its later events do nothing. No contact is loaded outside
//!   `touch_begin` and `touch_end`: `end_frame` and the mouse's events run on the mouse's state.
//!
//! ## 6. Hover After a Redraw
//! Areas are single-buffered: drawing never interleaves with events. After a draw moved
//! things, `end_frame` re-resolves the stored pointer; if the hot id changed and nothing is
//! captured it returns true and `ui.draw_frame` dispatches a synthetic `pointer_move` at the
//! pointer, so hover lands one frame late.
//!
//! ## 7. Keyboard Focus
//! `focus` is the id that receives keys and pastes. Widgets ask `focused(id)` (O(1)) and read
//! the event themselves; `hit` answers `none` for keyboard events, so pointer-only widgets
//! ignore them. Areas flagged `focusable` define the Tab order: their order in the area list,
//! which is draw order.
//! - A left press focuses the hot area when it is focusable and clears focus otherwise.
//! - Tab and Shift+Tab move to the next or previous focusable area, wrapping, with one scan of
//!   the areas: the only O(areas) keyboard path. A focus that was not drawn starts the cycle.
//!   When the focused area is flagged `tab` (an editor that indents), Tab and Shift+Tab stay
//!   with its widget and focus does not move; Escape still clears focus, which is how the
//!   keyboard leaves such a widget.
//! - Escape clears focus in `event_end`, after the widgets saw the key, so a field reads it as
//!   cancel; a move away by a press or Tab is visible during that event as `focus_lost(id)`,
//!   which a field reads as commit.
//! - A focused id that the last draw did not record stays focused; `focus_rect` is its area's
//!   rect from the last draw that recorded it (refreshed in `end_frame`, only while focused).
//! - `window_focus(false)` clears the held keys and the modifiers.
//! A browser key is `consumed` when a widget had focus or Tab moved it, unless it is a
//! clipboard shortcut, so the page's own copy, cut, and paste events still fire.
//!
//! ## 7a. File Drops
//! A file drag does not move the pointer (the drag holds it), so it has its own target: the
//! topmost area flagged `drop` under the drag's point, on a layer at least the hot area's
//! (`ui/areas.zig`, section 4), so a popup blocks drops beneath it. `drop_over` and `drop`
//! resolve it at their point and `drop_leave` clears it; hover, capture, and focus are
//! untouched, and `hit` answers `none` for the four drop events. `drop_hit(id, event)` answers
//! them instead, a separate call so the widgets that switch over `Hit` need no new arms:
//! ```text
//! drop_over   the target changed: the new one drop_in, the old one drop_out
//! drop_leave  the old target drop_out
//! drop        the target dropped { x, y, rect, files }; the drag is over after the event
//! file        the receiver (accept_files) file: the chunk
//! ```
//! `drop_hovering(id)` reports the target in any phase, so a drop zone highlights itself in
//! `draw` with no state of its own. During the `drop` event the app may call
//! `accept_files(id, mask)` once: `id` receives the files' chunks, and the host starts the
//! transfer after the dispatch (`take_files_accept`). `cancel_files(mask)` during any event ends
//! those files of the running transfer (`take_files_cancel`); the host dispatches their
//! `cancelled` chunks after the current dispatch (`input.zig`, section 6).
//!
//! ## 7b. Drags Between Widgets
//! A widget that holds the capture may turn its press into a drag between widgets:
//! `drag_begin(source, payload)` (event phase, one at a time) starts a session carrying a `u64`
//! the app interprets. The session rides on the capture, so `hit` is unchanged and the source
//! still gets `drag` and `up`; it ignores them while `dragging()` names it. Its target is the
//! topmost area flagged `drag_target` under the pointer, on a layer at least the hot area's
//! (`ui/areas.zig`, section 4), resolved like a file drop's from the first pointer event after
//! `drag_begin`:
//! ```text
//! move, down, wheel   the target at the point; the event owes a draw
//! left up             the target at the release point; the session is released
//! leave, Escape down  the target is cleared; the session is cancelled
//! event_end           a released or cancelled session is over
//! ```
//! `drag_hit(id, event)` answers them, a separate call like `drop_hit`:
//! ```text
//! target changed   the new target drag_in { over }, the old one drag_out
//! same target      the target over { over }                       (pointer moves only)
//! released         the target dropped { over }; the source ended { target, false }
//! cancelled        the old target drag_out; the source ended { .none, true }
//! ```
//! A source is never its own target: on release the source's `ended` is answered first.
//! `dragging()` and `drag_hovering(id)` report the session in any phase, so a source draws its
//! ghost and a target its marker in `draw` with no state of their own, and `cursor()` reads
//! `grabbing` while it lasts. File drops stay apart (section 7a): their events, lifetime, and
//! flag differ, so a file zone never receives a widget's drag and a drag target never files.
//!
//! ## 8. Cursor and Clipboard
//! The hot area's `Flags.cursor` is resolved with the hot area; `cursor()` reports it, the
//! captured area's cursor while a press is held (a held `grab` reads `grabbing`), and
//! `default` outside the window. `copy(bytes)` stores up to `clipboard_cap` bytes (cut on a
//! codepoint boundary) in `clipboard` and flags the host; `request_paste` asks the host for
//! the clipboard text, which arrives as a `paste` event routed to the focused widget.
//!
//! ## 9. The Timer Flag
//! `timer_setup(period_ms, armed)` (from the hosts, once) stores `App.config.timer_period_ms`
//! and sets `timer_on` to `period_ms != 0 and armed`. `set_timer(on)` changes the flag during
//! an event or a timer call; after each call into the app the hosts compare it with what
//! they armed and arm or disarm the timer (`timerfd_settime` natively, `setInterval` and
//! `clearInterval` in the browser), so a paused app sleeps. Setting it on an app without a
//! period is a programming error (asserted).
//!
//! ## 9a. The Audio Flag
//! `audio_setup(has_audio)` (from the hosts, once) records whether the app declares an
//! `Audio` source (`app.zig`); `audio_on` starts false. `set_audio(on)` during an event starts or
//! stops the source: the native host starts or parks its audio thread to match, and the
//! browser resumes or suspends its `AudioContext`, so a stopped app produces nothing and sleeps
//! (`realtime.zig`). Setting it on an app without a source is a programming error (asserted).
//! After each drain the hosts copy the queue's drop count into `audio_dropped`.
//!
//! ## 9b. The Theme
//! `scheme` is the app's `theme.Scheme` and `draw.theme` its GPU record (`theme.zig`, section
//! 1). `theme_setup(scheme)` (from `app.start`, once) copies `App.config.theme`; until then
//! both are `theme.dark`. `theme()` returns it in any phase, and widgets read their colors,
//! text styles, and hover and press weights from it at draw time; the scrollbar thumb is
//! `colors.control`. `set_theme(scheme)` during an event or a timer call stores a different
//! scheme, writes its record into `draw.theme`, and calls `redraw`; the same scheme again is
//! no change and owes nothing. The renderer sees the new record as a uniform change.
//!
//! ## 10. TigerStyle Invariants
//! - All storage is fixed: `turtle.depth_max` entries, `area_cap` areas, the clipboard, and the
//!   duplicate stamps of safe builds. Per-frame work is proportional to instances, areas, and
//!   depth; nothing capacity-sized is cleared per frame or per event.
//! - Overflowing areas are counted in `area_overflow` and are not hittable. `overflow()` gathers
//!   them with the refused instances and glyphs, and `overflow_report()` returns that only when
//!   it changed and is not zero, which both hosts log after a draw in safe builds.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const input = @import("../input.zig");
const theme_module = @import("../theme.zig");
const turtle = @import("turtle.zig");
const areas = @import("areas.zig");
const view = @import("view.zig");
const canvas = @import("canvas.zig");
const popup = @import("popup.zig");

pub const Rect = draw.Rect;
pub const Clip = draw.Clip;
pub const Id = areas.Id;
pub const Area = areas.Area;
pub const Flags = areas.Flags;
pub const Cursor = areas.Cursor;
pub const ViewState = view.ViewState;
pub const CanvasState = canvas.CanvasState;

/// Bytes `copy` keeps for the host to offer: one paste-sized buffer per context.
pub const clipboard_cap: u32 = 65536;

/// Every field of the context that means "the pointer": the mouse's are the context's own, a
/// contact's live here and are swapped in for its dispatch (module guide, section 5b). A field
/// added here must exist on the context with the same type: `swap_slot` reads it by name.
const PointerSlot = struct {
    pointer: input.Pointer,
    hot: Id,
    hot_rect: Rect,
    hot_focusable: bool,
    hot_cursor: Cursor,
    hot_window: areas.WindowPart,
    hot_primary_only: bool,
    wheel: Id,
    hover: Id,
    hover_prev: Id,
    capture: Id,
    capture_rect: Rect,
    capture_cursor: Cursor,
    pressed: bool,
    ending_capture: bool,

    fn fresh(window: Rect) PointerSlot {
        return .{
            .pointer = input.Pointer.init(),
            .hot = .none,
            .hot_rect = window,
            .hot_focusable = false,
            .hot_cursor = .default,
            .hot_window = .none,
            .hot_primary_only = false,
            .wheel = .none,
            .hover = .none,
            .hover_prev = .none,
            .capture = .none,
            .capture_rect = window,
            .capture_cursor = .default,
            .pressed = false,
            .ending_capture = false,
        };
    }
};

/// One finger (module guide, section 5b).
const Contact = struct {
    /// The host's id, unique among the contacts down.
    id: u32,
    live: bool,
    primary: bool,
    joined: bool,
    origin: [2]f32,
    down_ms: u32,
    /// The area under the press, held or not: a gesture's target.
    target: Id,
    slot: PointerSlot,
};

/// Which part of a touch the event being dispatched is.
pub const TouchPhase = enum(u8) { down, move, up, cancel };

/// The finger whose event is being dispatched, from `cx.touch()`.
pub const TouchInfo = struct {
    id: u32,
    primary: bool,
    phase: TouchPhase,
    x: f32,
    y: f32,
    origin: [2]f32,
    down_ms: u32,
    /// The area under the press (`.none` when there was none, or `primary_only` hid it).
    target: Id,
    /// The target was held by the mouse or another contact when this one landed.
    joined: bool,
    /// The time of this event: the host's stamp.
    time_ms: u32,
};

/// The pointer events a touch event means (module guide, section 5b): one, or two for a lift.
pub const TouchPlan = struct {
    events: [2]input.Event,
    count: u32,
};

fn idle_contact(window: Rect) Contact {
    return .{
        .id = 0,
        .live = false,
        .primary = false,
        .joined = false,
        .origin = .{ 0, 0 },
        .down_ms = 0,
        .target = .none,
        .slot = .fresh(window),
    };
}

/// What the context is doing; see the module guide, section 2.
pub const Phase = enum(u8) {
    idle,
    event,
    draw,
};

/// A press or drag sample, with the rect of the area that was hit at the last draw, the press
/// count of the click sequence, and the modifiers.
pub const Press = struct {
    x: f32,
    y: f32,
    rect: Rect,
    clicks: u8,
    mods: input.Mods,
};

/// What the app or a window area asked of the window manager (module guide, section 5a). The
/// host takes it after the dispatch (`take_window_request`).
pub const WindowRequest = union(enum) {
    /// Move the window with the pointer, from the press with this serial.
    move: u32,
    /// Resize the window from `edge` (never `none` or `drag`), from the press with `serial`.
    resize: struct { edge: areas.WindowPart, serial: u32 },
    /// Show the window manager's window menu at the point, for the press with `serial`.
    menu: struct { x: f32, y: f32, serial: u32 },
    minimize,
    /// Maximize, or restore while maximized.
    toggle_maximize,
    /// End the app: the host leaves its loop.
    close,
};

/// A release sample. `inside` is true when the pointer is still over the captured area.
pub const Up = struct {
    x: f32,
    y: f32,
    inside: bool,
};

/// What the last draw refused (module guide, section 10): instances (`draw.overflow_count`),
/// areas (`area_overflow`), and glyphs the atlas could not fit, for lack of room; and icons
/// whose face does not map their codepoint (`text.icon`), with the last as
/// `face << 21 | codepoint`.
pub const Overflow = struct {
    instances: u32,
    areas: u32,
    glyphs: u32,
    icons: u32 = 0,
    icon: u32 = 0,

    pub const zero: Overflow = .{ .instances = 0, .areas = 0, .glyphs = 0 };
};

/// What one event means for one id. See the module guide, section 5.
pub const Hit = union(enum) {
    none,
    hover_in,
    hover_out,
    down: Press,
    drag: Press,
    up: Up,
    wheel: input.Wheel,
    /// A right press on the hot area. It does not capture.
    secondary: Press,
};

/// A drop on an area: the drag's point, the area's rect at the last draw, and the files.
pub const Dropped = struct {
    x: f32,
    y: f32,
    rect: Rect,
    files: *const input.Drop,
};

/// What a file-drag event means for one id. See the module guide, section 7a.
pub const DropHit = union(enum) {
    none,
    /// The drag moved onto the area.
    drop_in,
    /// The drag moved off it, left the window, or ended.
    drop_out,
    dropped: Dropped,
    /// A chunk of a file the id accepted.
    file: *const input.Chunk,
};

/// A drag between widgets in flight (section 7b): its source and payload, the pointer, and
/// the target under it (`.none` when there is none).
pub const Dragging = struct {
    source: Id,
    payload: u64,
    x: f32,
    y: f32,
    target: Id,
};

/// A drag over a target or dropped on it: the pointer, the target's rect at the last draw,
/// the payload, and the source.
pub const DragOver = struct {
    x: f32,
    y: f32,
    rect: Rect,
    payload: u64,
    source: Id,
};

/// How a drag ended, for its source: the target it was dropped on (`.none` when it was
/// released over nothing or cancelled), and whether Escape or the pointer leaving the window
/// cancelled it.
pub const DragEnd = struct {
    target: Id,
    cancelled: bool,
};

/// What a pointer event (or Escape) means for one id during a drag between widgets. See the
/// module guide, section 7b.
pub const DragHit = union(enum) {
    none,
    /// The drag moved onto the target.
    drag_in: DragOver,
    /// The drag moved while over the target.
    over: DragOver,
    /// The drag moved off the target, was cancelled, or was released elsewhere.
    drag_out,
    /// The drag was released over the target.
    dropped: DragOver,
    /// To the source: the drag is over after this event.
    ended: DragEnd,
};

/// How the current event ends a drag session (section 7b).
const DragEnding = enum(u8) {
    none,
    released,
    cancelled,
};

/// No hover, press, or wheel interest beyond the default.
pub const plain: Flags = .{ .wheel = false, .focusable = false, .tab = false, .cursor = .default };
/// A press by a contact other than the primary one treats the area as absent: for a widget of
/// several ids that shares press state (module guide, section 5b).
pub const primary_flag: Flags = .{
    .wheel = false,
    .focusable = false,
    .tab = false,
    .cursor = .default,
    .primary_only = true,
};
/// Takes wheel input.
pub const wheel_flag: Flags = .{
    .wheel = true,
    .focusable = false,
    .tab = false,
    .cursor = .default,
};

/// Takes dropped files.
pub const drop_flag: Flags = .{
    .wheel = false,
    .focusable = false,
    .tab = false,
    .cursor = .default,
    .drop = true,
};

/// Takes drags between widgets (section 7b).
pub const drag_target_flag: Flags = .{
    .wheel = false,
    .focusable = false,
    .tab = false,
    .cursor = .default,
    .drag_target = true,
};

/// The layout of the root turtle: the window, flowing down, clipped to the window.
pub const root_layout: turtle.Layout = .{
    .flow = .down,
    .spacing = 0,
    .padding = turtle.zero_inset,
    .alignment = .{ .x = 0, .y = 0 },
    .clip = true,
};

/// The UI context over the draw context type `Draw`. See the module guide.
pub fn Context(comptime Draw: type, comptime area_cap: u32) type {
    comptime {
        assert(area_cap >= 1);
        assert(area_cap <= areas.area_cap_max);
    }
    const pool_count = Draw.Registry.count;
    const Entry = struct {
        turtle: turtle.Turtle,
        starts: [pool_count]u32,
        area_start: u32,
        clip: ?Clip,
        /// `clip_total` once this entry opened, its own clip included.
        clip_total: u32,
        /// Set for a view: its state, id, viewport, and the walk and rect in its parent.
        view: ?*ViewState,
        view_id: Id,
        /// The view's own area in `areas`, or null when it stored none.
        view_area: ?u32,
        viewport: Rect,
        outer_walk: turtle.Walk,
        outer_rect: Rect,
        /// Set for a canvas (section 3a): `end_canvas` closes it.
        is_canvas: bool,
        /// Set for a container `begin_at` placed (section 3b): it does not take part in its
        /// parent's flow.
        free: bool,
    };
    // The open canvas (section 3a).
    const Canvas = struct {
        view: draw.View,
        layer_before: draw.Layer,
    };
    // The open popup (section 3c).
    const Popup = struct {
        id: Id,
        layer_before: draw.Layer,
    };
    return struct {
        const Self = @This();

        draw: Draw,
        stack: [turtle.depth_max]Entry,
        depth: u32,
        /// Clipping containers opened this frame.
        clip_total: u32,
        areas: [area_cap]Area,
        area_count: u32,
        area_overflow: u32,
        stamps: areas.Stamps(area_cap),
        /// The window in logical pixels at the last `begin_frame`.
        window: Rect,
        phase: Phase,
        event_tag: std.meta.Tag(input.Event),
        pointer: input.Pointer,
        hot: Id,
        hot_rect: Rect,
        hot_focusable: bool,
        hot_cursor: Cursor,
        /// The hot area's window part (section 5a).
        hot_window: areas.WindowPart,
        wheel: Id,
        hover: Id,
        hover_prev: Id,
        capture: Id,
        capture_rect: Rect,
        capture_cursor: Cursor,
        /// True during the event whose `down` set the capture.
        pressed: bool,
        /// True during the left release that ends the capture.
        ending_capture: bool,
        /// The hot area's `Flags.primary_only` (section 5b).
        hot_primary_only: bool,
        /// The click sequence of the last press (`input.count_click`).
        clicks: input.Clicks,
        /// The fingers (section 5b): the table, the contact whose state is loaded while its
        /// events dispatch, what it is doing, the click sequence of fingers (swapped with
        /// `clicks` while one is loaded), and the counts a HUD shows.
        contacts: [input.contact_cap]Contact,
        contacts_live_count: u32,
        contacts_most: u32,
        contacts_refused: u32,
        touch_clicks: input.Clicks,
        touch_loaded: ?u32,
        touch_phase: TouchPhase,
        touch_time_ms: u32,
        /// The loaded contact holds nothing, so its moves and lifts resolve nothing.
        touch_quiet: bool,
        /// Keyboard focus and the focus when the current event began (section 7).
        focus: Id,
        focus_prev: Id,
        focus_rect: Rect,
        /// True during an Escape press; `event_end` then clears focus.
        escaping: bool,
        /// True after a key press a widget or Tab took (section 7).
        key_consumed: bool,
        /// Held keys as `Key.bit` flags, and the latest modifiers.
        keys_held: u64,
        mods: input.Mods,
        window_focused: bool,
        /// `copy` output: `clipboard[0..copy_len]`. The flags are for the host (section 8).
        clipboard: [clipboard_cap]u8,
        copy_len: u32,
        copy_pending: bool,
        paste_pending: bool,
        /// The file drag's target and the target when the current event began, and its rect
        /// at the last draw (section 7a).
        drop_target: Id,
        drop_prev: Id,
        drop_rect: Rect,
        /// Files listed by the `drop` being dispatched.
        drop_count: u8,
        /// The drag between widgets (section 7b): its source (`.none` when no drag is in
        /// flight) and payload, its target and the target when the current event began, the
        /// target's rect at the last draw, and how the current event ends it.
        drag_source: Id,
        drag_payload: u64,
        drag_target: Id,
        drag_prev: Id,
        drag_rect: Rect,
        drag_ending: DragEnding,
        /// The contact that began the session, or null for the mouse, and the pointer's last
        /// place in it (section 7b).
        drag_owner: ?u32,
        drag_x: f32,
        drag_y: f32,
        /// The id that accepted the running transfer, and the host's requests (section 7a).
        files_receiver: Id,
        files_accept: ?u16,
        files_cancel: u16,
        /// A draw is owed. Set by `redraw`, cleared by `begin_frame`.
        dirty: bool,
        /// An animator is still moving; see `keep_animating`.
        animating: bool,
        /// The host timer's period (`App.config.timer_period_ms`), 0 for an app without a
        /// timer, and whether the app wants it running (section 9). Hosts read `timer_on`.
        timer_period_ms: u32,
        timer_on: bool,
        /// Whether the app declares an audio source, and whether it wants it running
        /// (section 9a). Hosts read `audio_on`.
        has_audio: bool,
        audio_on: bool,
        /// Blocks the audio queue refused so far; the hosts copy it after each drain.
        audio_dropped: u32,
        /// The canvas being drawn, if any (section 3a).
        canvas_open: ?Canvas,
        /// The popup being drawn, if any, and the popups drawn this frame (section 3c).
        popup_open: ?Popup,
        popup_count: u32,
        /// The popup a widget opened (`request_popup`) and the one this frame drew or skipped;
        /// safe builds check at `end_frame` that a request was met (section 3c).
        popup_requested: Id,
        popup_met: Id,
        /// The window manager's last word on the window, and the request for the host to take
        /// (section 5a).
        window_state_value: input.WindowState,
        window_request: ?WindowRequest,
        /// The app's scheme (section 9b); `draw.theme` is its record.
        scheme: theme_module.Scheme,
        /// What `overflow_report` last returned or saw (section 10).
        overflow_seen: Overflow,

        pub const DrawContext = Draw;
        pub const capacity: u32 = area_cap;

        /// Initializes the draw context and an idle UI state that owes its first draw.
        /// Out-pointer init so a static context needs no stack copy.
        pub fn init(self: *Self) void {
            self.draw.init();
            self.stamps.init();
            self.depth = 0;
            self.clip_total = 0;
            self.area_count = 0;
            self.area_overflow = 0;
            self.window = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            self.phase = .idle;
            self.event_tag = .frame;
            self.pointer = input.Pointer.init();
            self.hot = .none;
            self.hot_rect = self.window;
            self.hot_focusable = false;
            self.hot_cursor = .default;
            self.hot_window = .none;
            self.hot_primary_only = false;
            self.wheel = .none;
            self.hover = .none;
            self.hover_prev = .none;
            self.capture = .none;
            self.capture_rect = self.window;
            self.capture_cursor = .default;
            self.pressed = false;
            self.ending_capture = false;
            self.clicks = .none;
            for (&self.contacts) |*contact| contact.* = idle_contact(self.window);
            self.contacts_live_count = 0;
            self.contacts_most = 0;
            self.contacts_refused = 0;
            self.touch_clicks = .none;
            self.touch_loaded = null;
            self.touch_phase = .move;
            self.touch_time_ms = 0;
            self.touch_quiet = false;
            self.drag_owner = null;
            self.drag_x = 0;
            self.drag_y = 0;
            self.focus = .none;
            self.focus_prev = .none;
            self.focus_rect = self.window;
            self.escaping = false;
            self.key_consumed = false;
            self.keys_held = 0;
            self.mods = .none;
            self.window_focused = true;
            self.copy_len = 0;
            self.copy_pending = false;
            self.paste_pending = false;
            self.drop_target = .none;
            self.drop_prev = .none;
            self.drop_rect = self.window;
            self.drop_count = 0;
            self.drag_source = .none;
            self.drag_payload = 0;
            self.drag_target = .none;
            self.drag_prev = .none;
            self.drag_rect = self.window;
            self.drag_ending = .none;
            self.files_receiver = .none;
            self.files_accept = null;
            self.files_cancel = 0;
            self.dirty = true;
            self.animating = false;
            self.timer_period_ms = 0;
            self.timer_on = false;
            self.has_audio = false;
            self.audio_on = false;
            self.audio_dropped = 0;
            self.canvas_open = null;
            self.popup_open = null;
            self.popup_count = 0;
            self.popup_requested = .none;
            self.popup_met = .none;
            self.overflow_seen = .zero;
            self.window_state_value = .{};
            self.window_request = null;
            self.scheme = theme_module.dark;
            self.draw.theme = self.scheme.record();
            assert(self.phase == .idle);
            assert(self.dirty);
        }

        /// Records the app's timer period and whether the timer runs from startup; the hosts
        /// call it once after `init` (section 9). A period of 0 never runs.
        pub fn timer_setup(self: *Self, period_ms: u32, armed: bool) void {
            assert(self.phase == .idle);
            self.timer_period_ms = period_ms;
            self.timer_on = period_ms != 0 and armed;
            if (period_ms == 0) assert(!self.timer_on);
        }

        /// Starts or stops the host timer. The host applies the change after the current call
        /// returns; a stopped timer calls no `App.timer` (section 9). Not during a draw, and
        /// only for an app that declared a timer period.
        pub fn set_timer(self: *Self, on: bool) void {
            assert(self.phase != .draw);
            assert(self.timer_period_ms != 0);
            self.timer_on = on;
            assert(self.timer_on == on);
        }

        /// Records whether the app declares an audio source; the hosts call it once after
        /// `init` (section 9a). The source starts stopped.
        pub fn audio_setup(self: *Self, has_audio: bool) void {
            assert(self.phase == .idle);
            self.has_audio = has_audio;
            self.audio_on = false;
        }

        /// Starts or stops the app's audio source. The host applies the change after the
        /// current call returns (section 9a). Not during a draw, and only for an app with a
        /// source.
        pub fn set_audio(self: *Self, on: bool) void {
            assert(self.phase != .draw);
            assert(self.has_audio);
            self.audio_on = on;
            assert(self.audio_on == on);
        }

        /// Records the app's starting scheme; the hosts call it once after `init` (section 9b).
        /// The first draw is already owed, so it marks nothing.
        pub fn theme_setup(self: *Self, scheme: theme_module.Scheme) void {
            assert(self.phase == .idle);
            assert(self.dirty);
            self.scheme = scheme;
            self.draw.theme = scheme.record();
        }

        /// The app's scheme, which widgets read their colors, text styles, and weights from
        /// (section 9b). Any phase.
        pub fn theme(self: *const Self) *const theme_module.Scheme {
            assert(self.depth <= turtle.depth_max);
            return &self.scheme;
        }

        /// Switches the app's scheme: stores it, gives the draw context its record, and owes a
        /// draw, which the renderer turns into one uniform write and a full repaint (section
        /// 9b). The current scheme again does nothing. Not during a draw.
        pub fn set_theme(self: *Self, scheme: theme_module.Scheme) void {
            assert(self.phase != .draw);
            if (std.meta.eql(scheme, self.scheme)) return;
            self.scheme = scheme;
            self.draw.theme = scheme.record();
            self.redraw();
            assert(self.dirty);
            assert(std.meta.eql(self.scheme, scheme));
        }

        /// What the last draw refused (section 10). Not during a draw.
        pub fn overflow(self: *const Self) Overflow {
            assert(self.phase != .draw);
            return .{
                .instances = self.draw.overflow_count,
                .areas = self.area_overflow,
                .glyphs = self.draw.text.overflow_count,
                .icons = self.draw.text.icon_missing,
                .icon = self.draw.text.icon_last,
            };
        }

        /// The last draw's overflow when it differs from what this last saw and is not all
        /// zero, else null, so a persistent overflow is reported once and again whenever it
        /// changes. The hosts log it after each draw in builds with runtime safety.
        pub fn overflow_report(self: *Self) ?Overflow {
            const now = self.overflow();
            if (std.meta.eql(now, self.overflow_seen)) return null;
            self.overflow_seen = now;
            if (std.meta.eql(now, Overflow.zero)) return null;
            return now;
        }

        /// Marks a draw as owed. Not during a draw.
        pub fn redraw(self: *Self) void {
            assert(self.phase != .draw);
            self.dirty = true;
            assert(self.dirty);
        }

        /// Asks the host for another frame because an animator is still moving.
        pub fn keep_animating(self: *Self) void {
            assert(self.phase == .event);
            self.animating = true;
            assert(self.animating);
        }

        /// The hovered id: the one the last event left hot, frozen while a capture is held.
        pub fn hovered(self: *const Self) Id {
            assert(self.depth <= turtle.depth_max);
            return self.hover;
        }

        // ---------------------------------------------------------------- frame

        /// Resets the draw context and the areas for a window of `width` by `height` logical
        /// pixels at `scale_120`, and pushes the root turtle.
        pub fn begin_frame(self: *Self, width: u32, height: u32, scale_120: u32) void {
            assert(self.phase == .idle);
            assert(width != 0);
            assert(height != 0);
            self.draw.text.scale_120 = scale_120;
            self.draw.reset();
            self.window = .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
            };
            self.area_count = 0;
            self.area_overflow = 0;
            self.stamps.next_frame();
            self.clip_total = 0;
            self.popup_count = 0;
            self.popup_met = .none;
            self.dirty = false;
            self.phase = .draw;
            self.stack[0] = self.entry_of(
                turtle.root(self.window, root_layout),
                clip_of(self.window),
            );
            self.depth = 1;
            assert(self.stack[0].clip != null);
        }

        /// Ends the frame. Returns true when the hot id under the stored pointer changed and
        /// nothing is captured, so the host owes a synthetic `pointer_move` (section 6).
        pub fn end_frame(self: *Self) bool {
            assert(self.phase == .draw);
            assert(self.depth == 1);
            assert(self.popup_open == null);
            self.depth = 0;
            self.phase = .idle;
            if (self.popup_requested != .none) {
                // A widget opened a popup that no draw_overlay reached (section 3c).
                if (std.debug.runtime_safety and self.popup_met != self.popup_requested) {
                    std.debug.panic(
                        "popup {x} was requested but not drawn: call ui.overlays(cx, app) " ++
                            "at the end of App.draw",
                        .{@backingInt(self.popup_requested)},
                    );
                }
                self.popup_requested = .none;
            }
            if (self.focus != .none) {
                if (self.find(self.focus)) |focused_area| {
                    self.focus_rect = rect_of(focused_area.rect);
                }
            }
            assert(self.touch_loaded == null);
            for (&self.contacts) |*contact| {
                if (!contact.live or contact.slot.capture == .none) continue;
                if (self.find(contact.slot.capture)) |area_held| {
                    contact.slot.capture_rect = rect_of(area_held.rect);
                }
            }
            if (self.capture != .none) {
                if (self.find(self.capture)) |captured| self.capture_rect = rect_of(captured.rect);
                return false;
            }
            if (!self.pointer.inside) return false;
            const live = self.areas[0..self.area_count];
            const points = self.draw.point_items();
            const found = areas.resolve(live, points, self.pointer.x, self.pointer.y);
            const next: Id = if (found.hot) |index| self.areas[index].id else .none;
            return next != self.hover;
        }

        /// The draw context, for `text.place` and app-defined appends. Draw phase only.
        pub fn drawing(self: *Self) *Draw {
            assert(self.phase == .draw);
            assert(self.depth >= 1);
            return &self.draw;
        }

        /// Appends one instance through the draw context. Draw phase only.
        pub fn append(
            self: *Self,
            comptime T: type,
            texture: ?draw.TextureId,
            instance: T,
        ) draw.AppendError!void {
            return self.drawing().append(T, texture, instance);
        }

        // --------------------------------------------------------------- layout

        /// Places a leaf for `walk` in the current container and returns its border box.
        pub fn walk(self: *Self, child: turtle.Walk) Rect {
            assert(child.width != .fit);
            assert(child.height != .fit);
            const current = self.top();
            const rect = turtle.place(&current.turtle, child);
            turtle.advance(&current.turtle, child, rect);
            assert(rect.width >= 0);
            assert(rect.height >= 0);
            return rect;
        }

        /// Opens a container for `child` laid out by `layout` and returns its border box (a
        /// fit axis is 0 until `end`).
        pub fn begin(self: *Self, child: turtle.Walk, layout: turtle.Layout) Rect {
            assert(self.depth < turtle.depth_max);
            const parent = self.top();
            const rect = turtle.place(&parent.turtle, child);
            var clipped = parent.clip;
            if (layout.clip) {
                assert(child.width != .fit);
                assert(child.height != .fit);
                self.clip_total += 1;
                clipped = intersect(parent.clip, rect);
            }
            self.stack[self.depth] = self.entry_of(turtle.open(rect, child, layout), clipped);
            self.depth += 1;
            assert(self.depth >= 2);
            return rect;
        }

        /// Closes the current container: aligns its children, resolves fit sizes, aligns
        /// itself, and advances its parent. Returns its final border box.
        pub fn end(self: *Self) Rect {
            assert(self.depth >= 2);
            const entry = &self.stack[self.depth - 1];
            assert(entry.view == null);
            assert(!entry.is_canvas);
            _ = self.shift_since(entry, turtle.main_shift(&entry.turtle));
            var rect = turtle.close(&entry.turtle);
            self.depth -= 1;
            // A free container keeps its rect and leaves its parent's flow alone (section 3b).
            if (entry.free) return rect;
            const parent = self.top();
            const moved = self.shift_since(entry, turtle.self_shift(
                &parent.turtle,
                entry.turtle.walk,
                rect,
            ));
            rect.x += moved[0];
            rect.y += moved[1];
            turtle.advance(&parent.turtle, entry.turtle.walk, rect);
            return rect;
        }

        /// Advances the current container's cursor by `span` without a child.
        pub fn skip(self: *Self, span: f32) void {
            assert(span >= 0);
            const current = self.top();
            const before = current.turtle.count;
            turtle.skip(&current.turtle, span);
            assert(current.turtle.count == before);
        }

        /// The border box the next child for `child` would get, without placing it. A
        /// container face drawn before `begin` uses it, so a shift of the children leaves
        /// the face in place.
        pub fn peek(self: *Self, child: turtle.Walk) Rect {
            const current = self.top();
            const before = current.turtle.count;
            const rect = turtle.peek(&current.turtle, child);
            assert(current.turtle.count == before);
            assert(rect.width >= 0);
            return rect;
        }

        /// True when the next child for `child` would fit the current container.
        pub fn fits(self: *Self, child: turtle.Walk) bool {
            const current = self.top();
            const before = current.turtle.count;
            const result = turtle.fits(&current.turtle, child);
            assert(current.turtle.count == before);
            return result;
        }

        /// The space the next child of the current container could use.
        pub fn remaining(self: *Self) Rect {
            const rect = turtle.remaining(&self.top().turtle);
            assert(rect.width >= 0);
            assert(rect.height >= 0);
            return rect;
        }

        /// The clip in effect, or null when it is empty.
        pub fn clip(self: *Self) ?Clip {
            const current = self.top().clip orelse return null;
            assert(current.x1 > current.x0);
            assert(current.y1 > current.y0);
            return current;
        }

        /// The clip in effect when `rect` has positive edges and overlaps it, else null: the
        /// cull test widgets apply before drawing.
        pub fn visible(self: *Self, rect: Rect) ?Clip {
            const current = self.top().clip orelse return null;
            if (!(rect.width > 0)) return null;
            if (!(rect.height > 0)) return null;
            if (rect.x >= current.x1) return null;
            if (rect.y >= current.y1) return null;
            if (rect.x + rect.width <= current.x0) return null;
            if (rect.y + rect.height <= current.y0) return null;
            assert(current.x1 > current.x0);
            assert(rect.width > 0);
            return current;
        }

        // ---------------------------------------------------------------- views

        /// Opens a scrolling view for `child`. `layout.padding` insets the viewport and the
        /// children flow by `layout` in the viewport minus the gutter, `scroll_y` above its
        /// top. Registers the view's wheel area first. Returns the viewport.
        pub fn begin_view(
            self: *Self,
            id: Id,
            child: turtle.Walk,
            layout: turtle.Layout,
            state: *ViewState,
        ) Rect {
            return self.begin_view_with(id, child, layout, state, wheel_flag);
        }

        /// `begin_view` whose own area carries `flags` (which take the wheel): a list box makes
        /// its view focusable, so Tab reaches it and its keys follow focus. A view with nothing
        /// to scroll drops the wheel flag, so the wheel reaches the view around it.
        pub fn begin_view_with(
            self: *Self,
            id: Id,
            child: turtle.Walk,
            layout: turtle.Layout,
            state: *ViewState,
            flags: Flags,
        ) Rect {
            assert(flags.wheel);
            assert(self.depth < turtle.depth_max);
            assert(child.width != .fit);
            assert(child.height != .fit);
            assert(layout.alignment.y == 0);
            const parent = self.top();
            const rect = turtle.place(&parent.turtle, child);
            const viewport = inset(rect, layout.padding);
            state.viewport = viewport;
            state.scroll_y = std.math.clamp(state.scroll_y, 0, state.max_scroll());
            const first_area = self.area_count;
            if (viewport.width > 0 and viewport.height > 0) {
                self.area(id, viewport, 0, flags);
            }
            const content: Rect = .{
                .x = viewport.x,
                .y = viewport.y - state.scroll_y,
                .width = @max(0, viewport.width - view.gutter_px),
                .height = @max(0, viewport.height),
            };
            var inner = layout;
            inner.padding = turtle.zero_inset;
            inner.clip = false;
            self.clip_total += 1;
            const clipped = intersect(parent.clip, viewport);
            var entry = self.entry_of(turtle.root(content, inner), clipped);
            entry.view = state;
            entry.view_id = id;
            entry.view_area = if (self.area_count > first_area) first_area else null;
            entry.viewport = viewport;
            entry.outer_walk = child;
            entry.outer_rect = rect;
            self.stack[self.depth] = entry;
            self.depth += 1;
            return viewport;
        }

        /// Closes the current view: stores the measured content height, advances the
        /// parent, and draws the thumb with its area when the content can scroll.
        pub fn end_view(self: *Self) void {
            assert(self.depth >= 2);
            const entry = &self.stack[self.depth - 1];
            assert(!entry.is_canvas);
            const state = entry.view.?;
            state.content_h = @max(0, entry.turtle.extent[1] - entry.turtle.rect.y);
            self.depth -= 1;
            const parent = self.top();
            turtle.advance(&parent.turtle, entry.outer_walk, entry.outer_rect);
            if (!(state.max_scroll() > 0)) {
                // Only now is this frame's content known, so a first frame scrolls at once.
                if (entry.view_area) |index| self.areas[index].flags.wheel = false;
                return;
            }
            if (!(state.viewport.height > 0)) return;
            const thumb = state.thumb_rect();
            const outer = parent.clip orelse return;
            const look: draw.BoxLook = .{
                .fill = self.scheme.colors.control,
                .radius = view.thumb_radius,
            };
            self.append(draw.Box, null, .of(thumb, outer, look)) catch |err| switch (err) {
                error.PoolFull, error.BatchFull => {},
                error.EdgeNotPositive, error.ClipUnordered => unreachable,
            };
            self.area(entry.view_id.derive(view.thumb_salt), thumb, 0, plain);
        }

        // ------------------------------------------------------------- canvases

        /// Opens a canvas for `child` (section 3a): `layout.padding` insets the viewport, the
        /// canvas's own wheel and pan area `id` covers it, and `layers` (1 to 4, none the base
        /// layer) get `state`'s view this frame. Until `end_canvas`, appends go to those layers
        /// (starting on the first), the turtle, clips, and `visible` work in world pixels, and
        /// areas are mapped to the screen. Canvases do not nest. Returns the viewport.
        pub fn begin_canvas(
            self: *Self,
            id: Id,
            child: turtle.Walk,
            layout: turtle.Layout,
            state: *CanvasState,
            layers: []const draw.Layer,
        ) Rect {
            assert(self.canvas_open == null);
            assert(self.depth < turtle.depth_max);
            assert(child.width != .fit);
            assert(child.height != .fit);
            assert(layers.len >= 1 and layers.len <= 4);
            const parent = self.top();
            const rect = turtle.place(&parent.turtle, child);
            const viewport = inset(rect, layout.padding);
            state.viewport = viewport;
            if (viewport.width > 0 and viewport.height > 0) {
                self.area(id, viewport, 0, wheel_flag);
            }
            const viewed = state.view_of(self.draw.text.scale_120);
            state.drawn = viewed;
            var mask: u8 = 0;
            for (layers) |layer_value| {
                self.draw.view(layer_value, viewed);
                mask |= @as(u8, 1) << @intCast(@backingInt(layer_value));
            }
            self.draw.open_views(mask, viewed.zoom);
            self.draw.text.zoom = canvas.glyph_zoom(viewed.zoom);
            const screen = intersect(parent.clip, viewport);
            const world_clip: ?Clip = if (screen) |outer| world_clip_of(viewed, outer) else null;
            const world = world_rect_of(viewed, viewport);
            var inner = layout;
            inner.padding = turtle.zero_inset;
            inner.clip = false;
            self.clip_total += 1;
            var entry = self.entry_of(turtle.root(world, inner), world_clip);
            entry.is_canvas = true;
            entry.viewport = viewport;
            entry.outer_walk = child;
            entry.outer_rect = rect;
            self.stack[self.depth] = entry;
            self.depth += 1;
            self.canvas_open = .{ .view = viewed, .layer_before = self.draw.layer(layers[0]) };
            assert(self.canvas_open.?.view.zoom > 0);
            return viewport;
        }

        /// Closes the open canvas: restores the layer and the glyph zoom and advances the
        /// parent by the canvas's walk.
        pub fn end_canvas(self: *Self) void {
            assert(self.depth >= 2);
            const entry = &self.stack[self.depth - 1];
            assert(entry.is_canvas);
            const open = self.canvas_open.?;
            self.depth -= 1;
            const parent = self.top();
            turtle.advance(&parent.turtle, entry.outer_walk, entry.outer_rect);
            _ = self.draw.layer(open.layer_before);
            self.draw.close_views();
            self.draw.text.zoom = 1;
            self.canvas_open = null;
        }

        /// The view of the open canvas, or null outside one.
        pub fn canvas_view(self: *const Self) ?draw.View {
            const open = self.canvas_open orelse return null;
            return open.view;
        }

        /// Opens a container at `rect` (fixed on both axes) in the current coordinates, laid
        /// out by `layout`, outside its parent's flow (section 3b). Close it with `end`, which
        /// returns `rect` and leaves the parent's cursor alone.
        pub fn begin_at(self: *Self, rect: Rect, layout: turtle.Layout) Rect {
            assert(self.depth < turtle.depth_max);
            assert(rect.width >= 0);
            assert(rect.height >= 0);
            const parent = self.top();
            var clipped = parent.clip;
            if (layout.clip) {
                self.clip_total += 1;
                clipped = intersect(parent.clip, rect);
            }
            var entry = self.entry_of(turtle.root(rect, layout), clipped);
            entry.free = true;
            self.stack[self.depth] = entry;
            self.depth += 1;
            assert(self.depth >= 2);
            return rect;
        }

        // --------------------------------------------------------------- popups

        /// Opens popup `id` at `rect` (section 3c): switches to `Layer.popup`, appends a dimmed
        /// face over the window when `dim > 0` (its alpha), records the backdrop area
        /// `popup_backdrop(id)` over the whole window, and opens a free container at `rect`
        /// laid out by `layout` under the window clip. Only at the root, outside a canvas, one
        /// popup per frame, and never while the popup layer draws offscreen. Returns `rect`.
        pub fn begin_popup(self: *Self, id: Id, rect: Rect, layout: turtle.Layout, dim: f32) Rect {
            assert(self.phase == .draw);
            assert(self.depth == 1);
            assert(self.canvas_open == null);
            assert(self.popup_open == null);
            assert(self.popup_count < popup.popup_depth_max);
            assert(dim >= 0 and dim <= 1);
            assert(rect.width > 0 and rect.height > 0);
            const popup_index: u8 = @backingInt(draw.Layer.popup);
            assert(self.draw.binding_of(popup_index) == null);
            assert(self.draw.view_of(popup_index) == null);
            const before = self.draw.layer(.popup);
            const window_clip = self.stack[0].clip.?;
            if (dim > 0) {
                const look: draw.BoxLook = .{ .fill = .{ 0, 0, 0, dim } };
                self.append(draw.Box, null, .of(self.window, window_clip, look)) catch |err| {
                    switch (err) {
                        error.PoolFull, error.BatchFull => {},
                        error.EdgeNotPositive, error.ClipUnordered => unreachable,
                    }
                };
            }
            self.area(self.popup_backdrop(id), self.window, 0, primary_flag);
            self.popup_open = .{ .id = id, .layer_before = before };
            self.popup_count += 1;
            self.popup_met = id;
            const opened = self.begin_at(rect, layout);
            assert(self.depth == 2);
            return opened;
        }

        /// Closes the open popup and restores the layer it opened over.
        pub fn end_popup(self: *Self) void {
            assert(self.depth == 2);
            const open = self.popup_open.?;
            assert(self.stack[1].free);
            _ = self.end();
            _ = self.draw.layer(open.layer_before);
            self.popup_open = null;
            assert(self.depth == 1);
            assert(self.draw.layer_now != .popup or open.layer_before == .popup);
        }

        /// The id of popup `id`'s backdrop area, which takes every press outside the popup.
        pub fn popup_backdrop(self: *const Self, id: Id) Id {
            assert(id != .none);
            assert(self.depth <= turtle.depth_max);
            return id.derive(popup.backdrop_salt);
        }

        /// Notes that popup `id` opened and owes its first draw: safe builds check at the end
        /// of that draw that its owner drew it or skipped it (section 3c). Not during a draw.
        pub fn request_popup(self: *Self, id: Id) void {
            assert(self.phase != .draw);
            assert(id != .none);
            self.popup_requested = id;
            self.redraw();
        }

        /// Notes that the owner of popup `id` reached it this frame but drew nothing, because
        /// its anchor was not drawn (section 3c). Draw phase.
        pub fn skip_popup(self: *Self, id: Id) void {
            assert(self.phase == .draw);
            assert(id != .none);
            self.popup_met = id;
        }

        // ---------------------------------------------------------------- areas

        /// Records a hit area for `id` over `rect` with corner `radius`, under the clip in
        /// effect, on the current layer. One area per id per frame.
        pub fn area(self: *Self, id: Id, rect: Rect, radius: f32, flags: Flags) void {
            assert(self.phase == .draw);
            assert(id != .none);
            assert(rect.width > 0);
            assert(rect.height > 0);
            assert(radius >= 0);
            const current = self.top().clip orelse return;
            if (self.area_count == area_cap) {
                self.area_overflow += 1;
                return;
            }
            // Only stored areas are stamped, so at most `area_cap` inserts fill the
            // 2 * area_cap slots and the probe always finds a free one.
            const fresh = self.stamps.insert(id);
            assert(fresh);
            var stored: Area = .{
                .id = id,
                .rect = .{ rect.x, rect.y, rect.width, rect.height },
                .clip = .{ current.x0, current.y0, current.x1, current.y1 },
                .radius = radius,
                .layer = @backingInt(self.draw.layer_now),
                .flags = flags,
                .pad = 0,
                .first_point = 0,
                .point_count = 0,
                .zoom = 1,
                .pad1 = 0,
            };
            // Inside a canvas, mapped to the screen (section 3a).
            if (self.canvas_open) |open| {
                const v = open.view;
                stored.rect = .{
                    v.x + v.zoom * rect.x,
                    v.y + v.zoom * rect.y,
                    v.zoom * rect.width,
                    v.zoom * rect.height,
                };
                stored.clip = .{
                    v.x + v.zoom * current.x0,
                    v.y + v.zoom * current.y0,
                    v.x + v.zoom * current.x1,
                    v.y + v.zoom * current.y1,
                };
                stored.radius = v.zoom * radius;
                stored.zoom = v.zoom;
            }
            self.areas[self.area_count] = stored;
            self.area_count += 1;
            assert(self.area_count <= area_cap);
        }

        /// Records a path area for `id`: the points within `width / 2 + path.hit_slop` of the
        /// path `placed` (from `draw.path`, this frame) under the clip in effect, on the
        /// current layer (`ui/areas.zig`, section 3). One area per id per frame.
        pub fn path_area(
            self: *Self,
            id: Id,
            placed: draw.path.Placed,
            width: f32,
            flags: Flags,
        ) void {
            assert(width > 0);
            assert(placed.count >= 1);
            assert(placed.first + placed.count <= self.draw.point_count);
            const radius = width * 0.5 + draw.path.hit_slop;
            const bounds = placed.bounds;
            const rect: Rect = .{
                .x = bounds.x - radius,
                .y = bounds.y - radius,
                .width = bounds.width + 2 * radius,
                .height = bounds.height + 2 * radius,
            };
            const before = self.area_count;
            self.area(id, rect, radius, flags);
            if (self.area_count == before) return;
            const recorded = &self.areas[before];
            recorded.first_point = placed.first;
            recorded.point_count = placed.count;
            assert(recorded.id == id);
        }

        /// The area recorded for `id` at the last draw, or null. O(areas): for tests and for
        /// anchoring something to a widget drawn earlier in the frame.
        pub fn find(self: *const Self, id: Id) ?Area {
            assert(id != .none);
            assert(self.area_count <= area_cap);
            for (self.areas[0..self.area_count]) |candidate| {
                if (candidate.id == id) return candidate;
            }
            return null;
        }

        /// The areas of the last draw, in append order.
        pub fn area_list(self: *const Self) []const Area {
            assert(self.area_count <= area_cap);
            return self.areas[0..self.area_count];
        }

        // ---------------------------------------------------------------- touch

        /// Exchanges the context's pointer state with `slot`'s (section 5b).
        fn swap_slot(self: *Self, slot: *PointerSlot) void {
            inline for (@typeInfo(PointerSlot).@"struct".field_names) |name| {
                std.mem.swap(
                    @TypeOf(@field(slot, name)),
                    &@field(self, name),
                    &@field(slot, name),
                );
            }
            std.mem.swap(input.Clicks, &self.clicks, &self.touch_clicks);
        }

        /// The index of the live contact with host id `id`.
        fn contact_of(self: *const Self, id: u32) ?u32 {
            for (&self.contacts, 0..) |*contact, index| {
                if (contact.live and contact.id == id) return @intCast(index);
            }
            return null;
        }

        /// True when contact `id` is down (so a repeated down must cancel it first).
        pub fn touch_live(self: *const Self, id: u32) bool {
            return self.contact_of(id) != null;
        }

        /// Contacts down now.
        pub fn contacts_live(self: *const Self) u32 {
            assert(self.contacts_live_count <= input.contact_cap);
            return self.contacts_live_count;
        }

        /// The ids of the live contacts, in table order, into `out`; how many there are.
        pub fn touch_ids(self: *const Self, out: *[input.contact_cap]u32) u32 {
            var count: u32 = 0;
            for (&self.contacts) |*contact| {
                if (!contact.live) continue;
                out[count] = contact.id;
                count += 1;
            }
            return count;
        }

        /// The finger whose event is being dispatched, or null for the mouse and for any other
        /// event (section 5b).
        pub fn touch(self: *const Self) ?TouchInfo {
            const index = self.touch_loaded orelse return null;
            const contact = &self.contacts[index];
            assert(contact.live);
            return .{
                .id = contact.id,
                .primary = contact.primary,
                .phase = self.touch_phase,
                .x = self.pointer.x,
                .y = self.pointer.y,
                .origin = contact.origin,
                .down_ms = contact.down_ms,
                .target = contact.target,
                .joined = contact.joined,
                .time_ms = self.touch_time_ms,
            };
        }

        /// The capture of the mouse, whichever state is loaded.
        fn mouse_capture(self: *const Self) Id {
            if (self.touch_loaded) |index| return self.contacts[index].slot.capture;
            return self.capture;
        }

        /// True when the mouse or a contact other than the one loaded holds `id`.
        fn held_elsewhere(self: *const Self, id: Id) bool {
            assert(id != .none);
            if (self.mouse_capture() == id) return true;
            for (&self.contacts, 0..) |*contact, index| {
                if (!contact.live) continue;
                if (self.touch_loaded) |loaded| if (loaded == index) continue;
                if (contact.slot.capture == id) return true;
            }
            return false;
        }

        /// True when the mouse or any contact holds `id` (a capture), in any phase.
        pub fn holds(self: *const Self, id: Id) bool {
            assert(id != .none);
            if (self.touch_loaded != null and self.capture == id) return true;
            return self.held_elsewhere(id) or self.capture == id;
        }

        /// Starts a touch dispatch: finds or claims the contact `event` is for, loads its
        /// pointer state, and returns the pointer events it means (section 5b), or null when
        /// the event is for no contact (an unknown id, a 17th finger, a cancel of nothing).
        /// `touch_end` must follow the dispatch of the events. Idle phase.
        pub fn touch_begin(self: *Self, event: input.Event) ?TouchPlan {
            assert(self.phase == .idle);
            assert(self.touch_loaded == null);
            var plan: TouchPlan = .{ .events = undefined, .count = 0 };
            var index: u32 = 0;
            switch (event) {
                .touch_down => |down| {
                    assert(self.contact_of(down.id) == null);
                    index = self.claim(down) orelse return null;
                    self.touch_phase = .down;
                    self.touch_time_ms = down.time_ms;
                    plan.events[0] = .{ .pointer_down = .{
                        .x = down.x,
                        .y = down.y,
                        .time_ms = down.time_ms,
                        .button = .left,
                        .mods = self.mods,
                        .serial = down.serial,
                    } };
                    plan.count = 1;
                },
                .touch_move => |move| {
                    index = self.contact_of(move.id) orelse return null;
                    self.touch_phase = .move;
                    self.touch_time_ms = move.time_ms;
                    plan.events[0] = .{ .pointer_move = .{ .x = move.x, .y = move.y } };
                    plan.count = 1;
                },
                .touch_up => |up| {
                    index = self.contact_of(up.id) orelse return null;
                    const last = self.contacts[index].slot.pointer;
                    self.touch_phase = .up;
                    self.touch_time_ms = up.time_ms;
                    plan.events[0] = .{ .pointer_up = .{
                        .x = last.x,
                        .y = last.y,
                        .time_ms = up.time_ms,
                        .button = .left,
                        .mods = self.mods,
                    } };
                    plan.events[1] = .pointer_leave;
                    plan.count = 2;
                },
                .touch_cancel => |named| {
                    index = self.contact_of(named orelse return null) orelse return null;
                    self.touch_phase = .cancel;
                    plan.events[0] = .pointer_leave;
                    plan.count = 1;
                },
                else => unreachable,
            }
            self.swap_slot(&self.contacts[index].slot);
            self.touch_loaded = index;
            // A finger that holds nothing resolves nothing on a move or a lift.
            self.touch_quiet = self.touch_phase != .down and self.capture == .none;
            assert(self.contacts[index].live);
            assert(plan.count >= 1);
            return plan;
        }

        /// Ends a touch dispatch: the mouse's state is back, and a lifted or cancelled contact
        /// is free (section 5b).
        pub fn touch_end(self: *Self) void {
            assert(self.phase == .idle);
            const index = self.touch_loaded orelse unreachable;
            self.swap_slot(&self.contacts[index].slot);
            self.touch_loaded = null;
            self.touch_quiet = false;
            if (self.touch_phase == .up or self.touch_phase == .cancel) {
                const contact = &self.contacts[index];
                assert(contact.live);
                assert(contact.slot.capture == .none);
                contact.live = false;
                contact.target = .none;
                self.contacts_live_count -= 1;
                if (self.drag_owner) |owner| assert(owner != index or self.drag_source == .none);
            }
            assert(self.touch_loaded == null);
        }

        /// Takes the first free contact for `down`, primary when no other is live.
        fn claim(self: *Self, down: input.Touch) ?u32 {
            for (&self.contacts, 0..) |*contact, index| {
                if (contact.live) continue;
                contact.* = .{
                    .id = down.id,
                    .live = true,
                    .primary = self.contacts_live_count == 0,
                    .joined = false,
                    .origin = .{ down.x, down.y },
                    .down_ms = down.time_ms,
                    .target = .none,
                    .slot = .fresh(self.window),
                };
                self.contacts_live_count += 1;
                self.contacts_most = @max(self.contacts_most, self.contacts_live_count);
                return @intCast(index);
            }
            self.contacts_refused += 1;
            return null;
        }

        // --------------------------------------------------------------- events

        /// Starts dispatching `event`: stores the pointer and resolves the hot area and the
        /// wheel target once (section 5), and applies focus, keys, and window focus (section 7).
        pub fn event_begin(self: *Self, event: input.Event) void {
            assert(self.phase == .idle);
            self.phase = .event;
            self.event_tag = event;
            self.hover_prev = self.hover;
            self.focus_prev = self.focus;
            self.drop_prev = self.drop_target;
            self.drag_prev = self.drag_target;
            self.drag_ending = .none;
            self.pressed = false;
            self.ending_capture = false;
            self.escaping = false;
            switch (event) {
                // Touch events are translated before they get here (section 5b).
                .touch_down, .touch_move, .touch_up, .touch_cancel => unreachable,
                .frame, .paste, .file => {},
                .drop_over => |point| self.drop_at(point.x, point.y),
                .drop_leave => self.drop_target = .none,
                .drop => |files| {
                    assert(files.count <= input.drop_files_max);
                    self.drop_count = files.count;
                    self.drop_at(files.x, files.y);
                },
                .pointer_leave => {
                    self.pointer.leave();
                    self.hot = .none;
                    self.hot_focusable = false;
                    self.hot_cursor = .default;
                    self.hot_window = .none;
                    self.hot_primary_only = false;
                    self.wheel = .none;
                    self.hover = .none;
                },
                .pointer_move => |point| self.point_at(point.x, point.y, false),
                .wheel => |wheel| self.point_at(wheel.x, wheel.y, false),
                .pointer_down => |down| self.press_at(down),
                .pointer_up => |up| {
                    self.mods = up.mods;
                    const left = up.button == .left;
                    if (left) self.pointer.button(false);
                    self.ending_capture = left and self.capture != .none;
                    self.point_at(up.x, up.y, left);
                },
                .key_down => |press| self.key_at(press),
                .key_up => |press| {
                    self.mods = press.mods;
                    self.keys_held &= ~press.key.bit();
                },
                .window_focus => |focused_now| {
                    self.window_focused = focused_now;
                    if (!focused_now) {
                        self.keys_held = 0;
                        self.mods = .none;
                    }
                },
                // Closing is the default; the app may answer with `keep_open` (section 5a).
                .close_requested => self.window_request = .close,
                .window_state => |state| {
                    self.window_state_value = state;
                    self.dirty = true;
                },
            }
            if (self.drag_source != .none and self.drag_sees(event)) self.drag_event(event);
            assert(self.phase == .event);
        }

        /// True when `event` is the drag session's to answer: any event but a pointer's, and a
        /// pointer's only from the pointer that began it (section 7b).
        fn drag_sees(self: *const Self, event: input.Event) bool {
            return switch (event) {
                .pointer_move, .pointer_down, .pointer_up, .pointer_leave, .wheel => {
                    return self.touch_loaded == self.drag_owner;
                },
                else => true,
            };
        }

        /// A session's part of `event_begin` (section 7b): pointer events owe a draw, a left
        /// release ends the session over its target, and a leave or Escape cancels it.
        fn drag_event(self: *Self, event: input.Event) void {
            assert(self.drag_source != .none);
            switch (event) {
                .pointer_move, .pointer_down, .wheel => {
                    assert(self.capture != .none);
                    self.dirty = true;
                    self.drag_x = self.pointer.x;
                    self.drag_y = self.pointer.y;
                },
                .pointer_up => |up| {
                    assert(self.capture != .none);
                    self.dirty = true;
                    self.drag_x = self.pointer.x;
                    self.drag_y = self.pointer.y;
                    if (up.button == .left) self.drag_ending = .released;
                },
                .pointer_leave => {
                    self.drag_target = .none;
                    self.drag_ending = .cancelled;
                    self.dirty = true;
                },
                .key_down => |press| if (press.key == .escape) {
                    self.drag_target = .none;
                    self.drag_ending = .cancelled;
                    self.dirty = true;
                },
                else => {},
            }
        }

        /// Finishes dispatching: a left release or a leave drops the capture, and an Escape
        /// press clears focus after the widgets saw it (section 7).
        pub fn event_end(self: *Self) void {
            assert(self.phase == .event);
            switch (self.event_tag) {
                .pointer_up => if (self.ending_capture) {
                    self.capture = .none;
                },
                .pointer_leave => self.capture = .none,
                // The drag is over, whatever the app did with it (section 7a).
                .drop => self.drop_target = .none,
                else => {},
            }
            if (self.drag_ending != .none) {
                self.drag_source = .none;
                self.drag_target = .none;
                self.drag_ending = .none;
            }
            if (self.drag_source != .none and self.touch_loaded == self.drag_owner) {
                assert(self.capture != .none);
            }
            if (self.escaping) self.focus = .none;
            self.phase = .idle;
            assert(self.phase == .idle);
        }

        /// What `event` means for `id`. O(1); see the module guide, section 5.
        pub fn hit(self: *const Self, id: Id, event: input.Event) Hit {
            assert(self.phase == .event);
            assert(id != .none);
            assert(@as(std.meta.Tag(input.Event), event) == self.event_tag);
            switch (event) {
                .frame, .key_down, .key_up, .paste, .window_focus => return .none,
                .drop_over, .drop_leave, .drop, .file => return .none,
                .close_requested, .window_state => return .none,
                // Translated to pointer events before `event_begin` (section 5b).
                .touch_down, .touch_move, .touch_up, .touch_cancel => return .none,
                .pointer_move => |point| {
                    if (self.capture != .none) return self.drag_of(id, point.x, point.y);
                    return self.hover_change(id);
                },
                .pointer_down => |down| {
                    if (down.button == .left) {
                        if (self.pressed and id == self.capture) {
                            return .{ .down = self.press_of(down.x, down.y, self.hot_rect) };
                        }
                        if (!self.pressed and self.capture != .none) {
                            return self.drag_of(id, down.x, down.y);
                        }
                        return self.hover_change(id);
                    }
                    if (self.capture != .none) return self.drag_of(id, down.x, down.y);
                    if (down.button == .right and id == self.hot) {
                        return .{ .secondary = self.press_of(down.x, down.y, self.hot_rect) };
                    }
                    return self.hover_change(id);
                },
                .pointer_up => |up| {
                    if (up.button != .left) {
                        if (self.capture != .none) return self.drag_of(id, up.x, up.y);
                        return self.hover_change(id);
                    }
                    if (self.capture == .none) return self.hover_change(id);
                    if (id == self.capture) {
                        const inside = self.hot == self.capture;
                        return .{ .up = .{ .x = up.x, .y = up.y, .inside = inside } };
                    }
                    if (id == self.hover and id != self.hover_prev) return .hover_in;
                    return .none;
                },
                .pointer_leave => {
                    if (id == self.capture) {
                        const at = self.pointer;
                        return .{ .up = .{ .x = at.x, .y = at.y, .inside = false } };
                    }
                    if (id == self.hover_prev) return .hover_out;
                    return .none;
                },
                .wheel => |wheel| {
                    if (id == self.wheel) return .{ .wheel = wheel };
                    if (self.capture != .none) return .none;
                    return self.hover_change(id);
                },
            }
        }

        /// What the file-drag event `event` means for `id`. O(1); see the module guide,
        /// section 7a.
        pub fn drop_hit(self: *const Self, id: Id, event: input.Event) DropHit {
            assert(self.phase == .event);
            assert(id != .none);
            assert(@as(std.meta.Tag(input.Event), event) == self.event_tag);
            switch (event) {
                .drop_over, .drop_leave => {
                    if (self.drop_target == self.drop_prev) return .none;
                    if (id == self.drop_target) return .drop_in;
                    if (id == self.drop_prev) return .drop_out;
                    return .none;
                },
                .drop => |files| {
                    if (id == self.drop_target) {
                        return .{ .dropped = .{
                            .x = files.x,
                            .y = files.y,
                            .rect = self.drop_rect,
                            .files = files,
                        } };
                    }
                    if (id == self.drop_prev) return .drop_out;
                    return .none;
                },
                .file => |chunk| {
                    if (id == self.files_receiver) return .{ .file = chunk };
                    return .none;
                },
                else => return .none,
            }
        }

        /// True while a file drag is over `id`'s area (section 7a). Any phase.
        pub fn drop_hovering(self: *const Self, id: Id) bool {
            assert(id != .none);
            assert(self.drop_count <= input.drop_files_max);
            return id == self.drop_target;
        }

        /// Host side: true while a file drag is over a drop target, so a drop here would be
        /// taken (the native host accepts the offer, the browser shows a copy cursor).
        pub fn drop_wanted(self: *const Self) bool {
            assert(self.phase == .idle);
            return self.drop_target != .none;
        }

        /// Takes the files in `mask` of the `drop` being dispatched; `id` receives their
        /// chunks (section 7a). Once per drop, during the `drop` event only.
        pub fn accept_files(self: *Self, id: Id, mask: u16) void {
            assert(self.phase == .event);
            assert(self.event_tag == .drop);
            assert(self.files_accept == null);
            assert(id != .none);
            assert(mask != 0);
            assert(self.drop_count == 16 or mask >> @intCast(self.drop_count) == 0);
            self.files_receiver = id;
            self.files_accept = mask;
            self.files_cancel = 0;
        }

        /// Ends the files in `mask` of the running transfer: each that has not ended gets one
        /// `cancelled` chunk after the current dispatch (section 7a). Event phase.
        pub fn cancel_files(self: *Self, mask: u16) void {
            assert(self.phase == .event);
            assert(mask != 0);
            self.files_cancel |= mask;
            assert(self.files_cancel != 0);
        }

        /// Host side: the mask of an `accept_files` during the last dispatch, once.
        pub fn take_files_accept(self: *Self) ?u16 {
            assert(self.phase == .idle);
            const accepted = self.files_accept;
            self.files_accept = null;
            assert(self.files_accept == null);
            return accepted;
        }

        /// Host side: the files `cancel_files` asked to end since the last call, once.
        pub fn take_files_cancel(self: *Self) u16 {
            assert(self.phase == .idle);
            const cancelled = self.files_cancel;
            self.files_cancel = 0;
            assert(self.files_cancel == 0);
            return cancelled;
        }

        /// Starts a drag between widgets from `source`, which holds the capture, carrying
        /// `payload` (section 7b). The target is resolved from the next pointer event on.
        /// Event phase; one drag at a time.
        pub fn drag_begin(self: *Self, source: Id, payload: u64) void {
            assert(self.phase == .event);
            assert(source != .none);
            assert(source == self.capture);
            assert(self.drag_source == .none);
            // Only the mouse and the primary contact begin one (section 7b).
            if (self.touch_loaded) |index| {
                if (!self.contacts[index].primary) return;
            }
            self.drag_owner = self.touch_loaded;
            self.drag_x = self.pointer.x;
            self.drag_y = self.pointer.y;
            self.drag_source = source;
            self.drag_payload = payload;
            self.drag_target = .none;
            self.drag_prev = .none;
            self.drag_ending = .none;
            self.dirty = true;
            assert(self.dragging() != null);
        }

        /// The drag between widgets in flight, or null (section 7b). Any phase.
        pub fn dragging(self: *const Self) ?Dragging {
            if (self.drag_source == .none) return null;
            return .{
                .source = self.drag_source,
                .payload = self.drag_payload,
                .x = self.drag_x,
                .y = self.drag_y,
                .target = self.drag_target,
            };
        }

        /// True while a drag between widgets is over `id`'s area (section 7b). Any phase.
        pub fn drag_hovering(self: *const Self, id: Id) bool {
            assert(id != .none);
            return self.drag_source != .none and id == self.drag_target;
        }

        /// What `event` means for `id` during a drag between widgets. O(1); see the module
        /// guide, section 7b.
        pub fn drag_hit(self: *const Self, id: Id, event: input.Event) DragHit {
            assert(self.phase == .event);
            assert(id != .none);
            assert(@as(std.meta.Tag(input.Event), event) == self.event_tag);
            if (self.drag_source == .none) return .none;
            if (!self.drag_sees(event)) return .none;
            const over: DragOver = .{
                .x = self.drag_x,
                .y = self.drag_y,
                .rect = self.drag_rect,
                .payload = self.drag_payload,
                .source = self.drag_source,
            };
            switch (self.drag_ending) {
                .released => {
                    if (id == self.drag_source) {
                        return .{ .ended = .{ .target = self.drag_target, .cancelled = false } };
                    }
                    if (id == self.drag_target) return .{ .dropped = over };
                    if (id == self.drag_prev) return .drag_out;
                    return .none;
                },
                .cancelled => {
                    if (id == self.drag_source) {
                        return .{ .ended = .{ .target = .none, .cancelled = true } };
                    }
                    if (id == self.drag_prev) return .drag_out;
                    return .none;
                },
                .none => {},
            }
            switch (event) {
                .pointer_move, .pointer_down, .pointer_up, .wheel => {},
                else => return .none,
            }
            if (self.drag_target != self.drag_prev) {
                if (id == self.drag_target) return .{ .drag_in = over };
                if (id == self.drag_prev) return .drag_out;
                return .none;
            }
            if (id == self.drag_target and event == .pointer_move) return .{ .over = over };
            return .none;
        }

        /// Resolves the drop target at the drag's point (section 7a). The pointer stays.
        fn drop_at(self: *Self, x: f32, y: f32) void {
            assert(x == x);
            assert(y == y);
            const live = self.areas[0..self.area_count];
            const found = areas.resolve(live, self.draw.point_items(), x, y);
            self.drop_target = .none;
            if (found.drop) |index| {
                self.drop_target = self.areas[index].id;
                self.drop_rect = rect_of(self.areas[index].rect);
            }
        }

        fn press_of(self: *const Self, x: f32, y: f32, rect: Rect) Press {
            assert(x == x);
            assert(self.clicks.count >= 1);
            return .{
                .x = x,
                .y = y,
                .rect = rect,
                .clicks = self.clicks.count,
                .mods = self.mods,
            };
        }

        fn drag_of(self: *const Self, id: Id, x: f32, y: f32) Hit {
            assert(self.capture != .none);
            assert(id != .none);
            if (id != self.capture) return .none;
            return .{ .drag = self.press_of(x, y, self.capture_rect) };
        }

        fn hover_change(self: *const Self, id: Id) Hit {
            assert(id != .none);
            assert(self.phase == .event);
            if (self.hover == self.hover_prev) return .none;
            if (id == self.hover) return .hover_in;
            if (id == self.hover_prev) return .hover_out;
            return .none;
        }

        /// Stores the pointer and resolves the hot area and wheel target under it. Hover
        /// follows the hot id unless a capture is held, except on the release that ends it.
        fn point_at(self: *Self, x: f32, y: f32, releasing: bool) void {
            assert(x == x);
            assert(y == y);
            self.pointer.move(x, y);
            // A finger that holds nothing resolves nothing (section 5b).
            if (self.touch_quiet) return;
            const live = self.areas[0..self.area_count];
            const found = areas.resolve(live, self.draw.point_items(), x, y);
            self.hot = .none;
            self.hot_focusable = false;
            self.hot_cursor = .default;
            self.hot_window = .none;
            self.hot_primary_only = false;
            self.wheel = .none;
            if (found.hot) |index| {
                const hot_area = &self.areas[index];
                self.hot = hot_area.id;
                self.hot_rect = rect_of(hot_area.rect);
                self.hot_focusable = hot_area.flags.focusable;
                self.hot_cursor = hot_area.flags.cursor;
                self.hot_window = hot_area.flags.window;
                self.hot_primary_only = hot_area.flags.primary_only;
            }
            if (found.wheel) |index| self.wheel = self.areas[index].id;
            if (self.drag_source != .none and self.touch_loaded == self.drag_owner) {
                self.drag_target = .none;
                if (found.drag) |index| {
                    self.drag_target = self.areas[index].id;
                    self.drag_rect = rect_of(self.areas[index].rect);
                }
            }
            if (self.capture == .none or releasing) self.hover = self.hot;
            assert(self.pointer.inside);
        }

        /// A press: counts the click, and a left press captures the hot area and moves focus
        /// to it when it is focusable, or clears focus (section 7).
        fn press_at(self: *Self, down: input.Button) void {
            self.mods = down.mods;
            const slop: f32 = if (self.touch_loaded != null)
                input.touch_click_slop_px
            else
                input.click_slop_px;
            self.clicks = input.count_click_within(self.clicks, down, slop);
            if (down.button != .left) {
                self.point_at(down.x, down.y, false);
                if (down.button == .right and self.capture == .none) _ = self.window_press(down);
                return;
            }
            self.pointer.button(true);
            self.point_at(down.x, down.y, false);
            if (self.capture != .none) return;
            var primary = true;
            if (self.touch_loaded) |index| {
                if (self.touch_press_hidden(index)) return;
                primary = self.contacts[index].primary;
            }
            if (primary and self.window_press(down)) {
                // The window manager takes the pointer: no capture, as for an unfocusable press.
                self.focus = .none;
                return;
            }
            if (self.hot != .none) {
                self.capture = self.hot;
                self.capture_rect = self.hot_rect;
                self.capture_cursor = self.hot_cursor;
                self.pressed = true;
            }
            // Only the primary contact moves focus: a second finger on a pad leaves a field alone.
            if (primary) {
                self.focus = if (self.hot_focusable) self.hot else .none;
                if (self.focus != .none) self.focus_rect = self.hot_rect;
            }
            assert(self.clicks.count >= 1);
        }

        /// A contact's press on the hot area (section 5b): records the contact's target, and
        /// when the area is `primary_only` for a non-primary contact, or another pointer holds
        /// it, clears what the press resolved so widgets see nothing. True when it did.
        fn touch_press_hidden(self: *Self, index: u32) bool {
            const contact = &self.contacts[index];
            assert(contact.live);
            const absent = self.hot_primary_only and !contact.primary;
            contact.target = if (absent) .none else self.hot;
            const joined = !absent and self.hot != .none and self.held_elsewhere(self.hot);
            contact.joined = joined;
            if (!absent and !joined) return false;
            self.hot = .none;
            self.hot_focusable = false;
            self.hot_cursor = .default;
            self.hot_window = .none;
            self.hot_primary_only = false;
            self.wheel = .none;
            self.hover = .none;
            return true;
        }

        /// A press on a window area: the request it makes (section 5a), and true when it made
        /// one with the left button.
        fn window_press(self: *Self, down: input.Button) bool {
            assert(self.phase == .event);
            const part = self.hot_window;
            if (part == .none) return false;
            if (down.button == .right) {
                if (part != .drag) return false;
                self.window_request = .{
                    .menu = .{ .x = down.x, .y = down.y, .serial = down.serial },
                };
                return false;
            }
            assert(down.button == .left);
            self.window_request = switch (part) {
                .none => unreachable,
                .drag => if (self.clicks.count == 2) .toggle_maximize else .{ .move = down.serial },
                else => .{ .resize = .{ .edge = part, .serial = down.serial } },
            };
            return true;
        }

        /// A key press: holds the key, cycles focus on Tab, notes Escape, and decides whether
        /// the browser should keep the key from the page (section 7).
        fn key_at(self: *Self, press: input.KeyPress) void {
            self.mods = press.mods;
            self.keys_held |= press.key.bit();
            self.escaping = press.key == .escape;
            if (press.key == .tab and !press.mods.shortcut() and !press.mods.alt) {
                if (!self.focus_keeps_tab()) self.cycle_focus(press.mods.shift);
            }
            const clipboard_key = press.key == .c or press.key == .x or press.key == .v;
            const shortcut = press.mods.shortcut() and clipboard_key;
            const routed = self.focus_prev != .none or self.focus != .none;
            self.key_consumed = routed and !shortcut;
            if (shortcut) assert(!self.key_consumed);
        }

        /// True when the focused area of the last draw is flagged `tab`, so Tab goes to its
        /// widget. One scan of the areas, on the Tab path only (section 7).
        fn focus_keeps_tab(self: *const Self) bool {
            assert(self.phase == .event);
            if (self.focus == .none) return false;
            const focused_area = self.find(self.focus) orelse return false;
            assert(focused_area.flags.focusable);
            return focused_area.flags.tab;
        }

        /// Moves focus to the next focusable area in draw order, or the previous one when
        /// `backward`, wrapping. One scan of the areas; nothing focusable leaves focus as is.
        fn cycle_focus(self: *Self, backward: bool) void {
            var first: ?u32 = null;
            var last: ?u32 = null;
            var before: ?u32 = null;
            var after: ?u32 = null;
            var seen = false;
            for (self.areas[0..self.area_count], 0..) |candidate, index| {
                if (!candidate.flags.focusable) continue;
                const at: u32 = @intCast(index);
                if (first == null) first = at;
                last = at;
                if (candidate.id == self.focus) {
                    seen = true;
                } else if (!seen) {
                    before = at;
                } else if (after == null) {
                    after = at;
                }
            }
            const chosen: ?u32 = if (!seen)
                (if (backward) last else first)
            else if (backward)
                (before orelse last)
            else
                (after orelse first);
            const index = chosen orelse return;
            assert(index < self.area_count);
            self.focus = self.areas[index].id;
            self.focus_rect = rect_of(self.areas[index].rect);
        }

        // ---------------------------------------------------------------- focus

        /// True when `id` has keyboard focus.
        pub fn focused(self: *const Self, id: Id) bool {
            assert(id != .none);
            assert(self.area_count <= area_cap);
            return self.focus == id;
        }

        /// True during the event that gave `id` focus.
        pub fn focus_gained(self: *const Self, id: Id) bool {
            assert(self.phase == .event);
            assert(id != .none);
            return self.focus == id and self.focus_prev != id;
        }

        /// True during the event that took focus from `id` (a press elsewhere or Tab).
        pub fn focus_lost(self: *const Self, id: Id) bool {
            assert(self.phase == .event);
            assert(id != .none);
            return self.focus_prev == id and self.focus != id;
        }

        /// Gives `id` focus, as a widget that opens an editor does. Event phase only.
        pub fn set_focus(self: *Self, id: Id) void {
            assert(self.phase == .event);
            assert(id != .none);
            self.focus = id;
            if (self.find(id)) |found| self.focus_rect = rect_of(found.rect);
            assert(self.focus == id);
        }

        /// Clears focus, as a field does when Enter commits. Event phase only.
        pub fn clear_focus(self: *Self) void {
            assert(self.phase == .event);
            self.focus = .none;
            assert(self.focus == .none);
        }

        /// The focused area's rect at the last draw that recorded it (section 7).
        pub fn focused_rect(self: *const Self) Rect {
            assert(self.focus != .none);
            assert(self.focus_rect.width >= 0);
            return self.focus_rect;
        }

        /// True while `key` is held.
        pub fn held(self: *const Self, key: input.Key) bool {
            assert(key != .other);
            assert(self.phase != .draw);
            return self.keys_held & key.bit() != 0;
        }

        /// True when the last key press went to a widget or moved focus (section 7).
        pub fn consumed(self: *const Self) bool {
            assert(self.phase == .idle);
            assert(self.event_tag == .key_down);
            return self.key_consumed;
        }

        // ------------------------------------------------------ cursor, clipboard

        /// The pointer shape to show (section 8).
        pub fn cursor(self: *const Self) Cursor {
            assert(self.phase != .draw);
            if (self.drag_source != .none) return .grabbing;
            if (self.capture != .none) {
                if (self.capture_cursor == .grab) return .grabbing;
                return self.capture_cursor;
            }
            if (!self.pointer.inside) return .default;
            return self.hot_cursor;
        }

        /// Stores `utf8` (cut to `clipboard_cap` on a codepoint boundary) for the host to offer
        /// as the clipboard selection. Event phase only.
        pub fn copy(self: *Self, utf8: []const u8) void {
            assert(self.phase == .event);
            const length = input.utf8_prefix(utf8, clipboard_cap);
            @memcpy(self.clipboard[0..length], utf8[0..length]);
            self.copy_len = length;
            self.copy_pending = true;
            assert(self.copy_len <= clipboard_cap);
        }

        /// The bytes of the last `copy`.
        pub fn copied(self: *const Self) []const u8 {
            assert(self.copy_len <= clipboard_cap);
            return self.clipboard[0..self.copy_len];
        }

        /// Host side: true once after a `copy`.
        pub fn take_copy(self: *Self) bool {
            assert(self.phase == .idle);
            const pending = self.copy_pending;
            self.copy_pending = false;
            assert(!self.copy_pending);
            return pending;
        }

        /// Asks the host for the clipboard text; it arrives as a `paste` event. Event phase.
        pub fn request_paste(self: *Self) void {
            assert(self.phase == .event);
            self.paste_pending = true;
            assert(self.paste_pending);
        }

        /// Host side: true once after a `request_paste`.
        pub fn take_paste_request(self: *Self) bool {
            assert(self.phase == .idle);
            const pending = self.paste_pending;
            self.paste_pending = false;
            assert(!self.paste_pending);
            return pending;
        }

        // ------------------------------------------------------------------ window

        /// The window manager's last word on the window (section 5a). Any phase.
        pub fn window_state(self: *const Self) input.WindowState {
            assert(self.window_state_value.unused == 0);
            return self.window_state_value;
        }

        /// Asks the window manager to minimize the window. Event phase.
        pub fn minimize(self: *Self) void {
            self.request_window(.minimize);
        }

        /// Asks the window manager to maximize the window, or to restore it while maximized.
        /// Event phase.
        pub fn toggle_maximize(self: *Self) void {
            self.request_window(.toggle_maximize);
        }

        /// Ends the app after the current event (natively; the browser ignores it). Event phase.
        pub fn close(self: *Self) void {
            self.request_window(.close);
        }

        /// Cancels a pending close: during `close_requested`, the window stays. Event phase.
        pub fn keep_open(self: *Self) void {
            assert(self.phase == .event);
            if (self.window_request) |request| {
                if (request == .close) self.window_request = null;
            }
            assert(self.window_request == null or self.window_request.? != .close);
        }

        fn request_window(self: *Self, request: WindowRequest) void {
            assert(self.phase == .event);
            assert(request != .move and request != .resize and request != .menu);
            self.window_request = request;
        }

        /// Host side: the request the last dispatches left, once (section 5a).
        pub fn take_window_request(self: *Self) ?WindowRequest {
            assert(self.phase == .idle);
            const request = self.window_request;
            self.window_request = null;
            assert(self.window_request == null);
            return request;
        }

        // ------------------------------------------------------------- internals

        fn top(self: *Self) *Entry {
            assert(self.phase == .draw);
            assert(self.depth >= 1);
            assert(self.depth <= turtle.depth_max);
            return &self.stack[self.depth - 1];
        }

        fn entry_of(self: *const Self, value: turtle.Turtle, clipped: ?Clip) Entry {
            assert(value.count == 0);
            assert(self.area_count <= area_cap);
            return .{
                .turtle = value,
                .starts = self.draw.counts(),
                .area_start = self.area_count,
                .clip = clipped,
                .clip_total = self.clip_total,
                .view = null,
                .view_id = .none,
                .view_area = null,
                .viewport = value.rect,
                .outer_walk = value.walk,
                .outer_rect = value.rect,
                .is_canvas = false,
                .free = false,
            };
        }

        /// Snaps `delta` to device pixels and moves what `entry` drew by it (section 4).
        /// Returns the delta applied.
        fn shift_since(self: *Self, entry: *const Entry, delta: [2]f32) [2]f32 {
            assert(delta[0] >= 0);
            assert(delta[1] >= 0);
            assert(entry.area_start <= self.area_count);
            const scale = self.draw.text.device_scale();
            const dx = @round(delta[0] * scale) / scale;
            const dy = @round(delta[1] * scale) / scale;
            if (dx == 0 and dy == 0) return .{ 0, 0 };
            // Clips do not move, so nothing inside may have set one (section 4).
            assert(self.clip_total == entry.clip_total);
            self.draw.shift(entry.starts, dx, dy);
            // Areas inside a canvas are in screen pixels (section 3a).
            const area_scale: f32 = if (self.canvas_open) |open| open.view.zoom else 1;
            for (self.areas[entry.area_start..self.area_count]) |*moved| {
                moved.rect[0] += dx * area_scale;
                moved.rect[1] += dy * area_scale;
            }
            return .{ dx, dy };
        }
    };
}

/// The world clip under the screen clip `outer` through `v` (section 3a).
fn world_clip_of(v: draw.View, outer: Clip) Clip {
    assert(v.zoom > 0);
    const low = v.invert(outer.x0, outer.y0);
    const high = v.invert(outer.x1, outer.y1);
    const out: Clip = .{ .x0 = low[0], .y0 = low[1], .x1 = high[0], .y1 = high[1] };
    assert(out.x1 > out.x0);
    assert(out.y1 > out.y0);
    return out;
}

/// The world rect under the screen rect `rect` through `v`.
fn world_rect_of(v: draw.View, rect: Rect) Rect {
    assert(v.zoom > 0);
    const origin = v.invert(rect.x, rect.y);
    const width = rect.width / v.zoom;
    return .{ .x = origin[0], .y = origin[1], .width = width, .height = rect.height / v.zoom };
}

/// The clip of a rect with positive edges.
pub fn clip_of(rect: Rect) Clip {
    assert(rect.width > 0);
    assert(rect.height > 0);
    assert(rect.x == rect.x);
    return .{ .x0 = rect.x, .y0 = rect.y, .x1 = rect.x + rect.width, .y1 = rect.y + rect.height };
}

/// `clip` intersected with `rect`, or null when the result is empty.
pub fn intersect(clip: ?Clip, rect: Rect) ?Clip {
    assert(rect.width == rect.width);
    assert(rect.height == rect.height);
    const outer = clip orelse return null;
    const out: Clip = .{
        .x0 = @max(outer.x0, rect.x),
        .y0 = @max(outer.y0, rect.y),
        .x1 = @min(outer.x1, rect.x + rect.width),
        .y1 = @min(outer.y1, rect.y + rect.height),
    };
    if (!(out.x1 > out.x0)) return null;
    if (!(out.y1 > out.y0)) return null;
    return out;
}

/// `rect` inset by `padding`; edges may go negative.
pub fn inset(rect: Rect, padding: draw.Inset) Rect {
    assert(padding.left >= 0);
    assert(padding.right >= 0);
    return .{
        .x = rect.x + padding.left,
        .y = rect.y + padding.top,
        .width = rect.width - padding.left - padding.right,
        .height = rect.height - padding.top - padding.bottom,
    };
}

fn rect_of(values: [4]f32) Rect {
    assert(values[2] == values[2]);
    assert(values[3] == values[3]);
    return .{ .x = values[0], .y = values[1], .width = values[2], .height = values[3] };
}

const testing = std.testing;
const text = @import("../text.zig");

const test_draw = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = 64 },
    .{ .type = draw.Glyph, .cap = 64 },
};

const TestContext = Context(draw.Context(&test_draw, 8, 0), 64);

/// A freshly initialized static context, so tests keep the pools off the stack.
fn new_context() *TestContext {
    const static = struct {
        var context: TestContext = undefined;
    };
    static.context.init();
    return &static.context;
}

fn sized(width: turtle.Size, height: turtle.Size) turtle.Walk {
    return .{ .width = width, .height = height, .margin = turtle.zero_inset };
}

fn flow_of(flow: turtle.Flow) turtle.Layout {
    var layout = root_layout;
    layout.flow = flow;
    layout.clip = false;
    return layout;
}

fn box(context: *TestContext, rect: Rect) void {
    const current = context.clip().?;
    context.append(draw.Box, null, .of(rect, current, .{ .fill = .{ 1, 1, 1, 1 } })) catch
        unreachable;
}

fn rect_at(x: f32, y: f32, width: f32, height: f32) Rect {
    return .{ .x = x, .y = y, .width = width, .height = height };
}

/// Dispatches `event` and writes what it means for each of `ids` into `out`.
fn send(context: *TestContext, event: input.Event, ids: []const Id, out: []Hit) void {
    assert(ids.len == out.len);
    context.event_begin(event);
    for (ids, out) |key, *result| result.* = context.hit(key, event);
    context.event_end();
}

// Locks the post-hoc alignment: a fit row in a centered column measures its children, and
// `end` moves its instances and areas by the snapped delta, so at scale 1.5 the glyphs stay
// on device pixels.
test "a fit container measures its children and alignment shifts their instances" {
    const context = new_context();
    context.begin_frame(300, 200, 180);
    var column = flow_of(.down);
    column.alignment.x = 0.5;
    _ = context.begin(sized(.fill, .fill), column);
    _ = context.begin(sized(.fit, .fit), flow_of(.right));
    const face = context.walk(sized(.{ .fixed = 40 }, .{ .fixed = 20 }));
    box(context, face);
    context.area(areas.id("face", 0), face, 0, plain);
    const label = context.walk(sized(.{ .fixed = 41 }, .{ .fixed = 20 }));
    const style: text.Style = .{ .face = .sans, .size = 16, .color = .{ 1, 1, 1, 1 } };
    const options: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
    text.place(context.drawing(), style, "Hi", label, context.clip().?, options);
    const row = context.end();
    // Width 81, slack 219, half of it 109.5 logical = 164.25 device px, snapped to 164.
    try testing.expectEqual(@as(f32, 164.0 / 1.5), row.x);
    try testing.expectEqual(@as(f32, 81), row.width);
    try testing.expectEqual(row.x, context.draw.items(draw.Box)[0].rect[0]);
    try testing.expectEqual(row.x, context.find(areas.id("face", 0)).?.rect[0]);
    const glyphs = context.draw.items(draw.Glyph);
    try testing.expect(glyphs.len >= 1);
    for (glyphs) |glyph| {
        const device = glyph.rect[0] * 1.5;
        try testing.expectApproxEqAbs(@round(device), device, 0.001);
    }
    _ = context.end();
    try testing.expect(!context.end_frame());
    try testing.expectEqual(@as(u32, 0), context.draw.overflow_count);
}

// Locks hit resolution: hover moves to the topmost area (the overlay layer wins over a later
// base area), a press captures, the capture persists across a redraw that moved the area and
// its drags carry the new rect, and a release outside reports `inside = false`.
test "topmost wins and capture persists across frames" {
    const context = new_context();
    const panel = areas.id("panel", 0);
    const knob = areas.id("knob", 0);
    const tip = areas.id("tip", 0);
    context.begin_frame(400, 300, 120);
    context.area(panel, rect_at(0, 0, 200, 200), 0, plain);
    const previous = context.draw.layer(.overlay);
    context.area(tip, rect_at(80, 80, 50, 50), 0, plain);
    _ = context.draw.layer(previous);
    context.area(knob, rect_at(50, 50, 50, 50), 0, plain);
    try testing.expect(!context.end_frame());
    const ids = [_]Id{ panel, knob, tip };
    var out: [3]Hit = undefined;
    send(context, .{ .pointer_move = .{ .x = 60, .y = 60 } }, &ids, &out);
    try testing.expectEqual(Hit.none, out[0]);
    try testing.expectEqual(Hit.hover_in, out[1]);
    send(context, .{ .pointer_move = .{ .x = 90, .y = 90 } }, &ids, &out);
    try testing.expectEqual(Hit.hover_out, out[1]);
    try testing.expectEqual(Hit.hover_in, out[2]);
    send(context, .{ .pointer_down = input.left_at(.{ .x = 60, .y = 60 }) }, &ids, &out);
    try testing.expectEqual(@as(f32, 50), out[1].down.rect.x);
    try testing.expectEqual(Hit.hover_out, out[2]);
    try testing.expectEqual(knob, context.hovered());
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(150, 50, 50, 50), 0, plain);
    try testing.expect(!context.end_frame());
    send(context, .{ .pointer_move = .{ .x = 170, .y = 60 } }, &ids, &out);
    try testing.expectEqual(@as(f32, 150), out[1].drag.rect.x);
    try testing.expectEqual(Hit.none, out[0]);
    send(context, .{ .pointer_up = input.left_at(.{ .x = 390, .y = 290 }) }, &ids, &out);
    try testing.expect(!out[1].up.inside);
    try testing.expectEqual(Id.none, context.capture);
    try testing.expectEqual(Id.none, context.hovered());
}

// Locks clipping: an area under a clipping container hits only inside the clip, and a fully
// clipped container records nothing.
test "clipped areas do not hit" {
    const context = new_context();
    context.begin_frame(400, 300, 120);
    var clipped = flow_of(.down);
    clipped.clip = true;
    _ = context.begin(sized(.{ .fixed = 100 }, .{ .fixed = 100 }), clipped);
    context.area(areas.id("wide", 0), rect_at(0, 0, 300, 50), 0, plain);
    try testing.expectEqual(@as(?Clip, clip_of(rect_at(0, 0, 100, 100))), context.clip());
    _ = context.begin(sized(.{ .fixed = 0 }, .{ .fixed = 10 }), clipped);
    try testing.expectEqual(@as(?Clip, null), context.clip());
    context.area(areas.id("hidden", 0), rect_at(0, 0, 10, 10), 0, plain);
    _ = context.end();
    _ = context.end();
    _ = context.end_frame();
    try testing.expectEqual(@as(usize, 1), context.area_list().len);
    var out: [1]Hit = undefined;
    const ids = [_]Id{areas.id("wide", 0)};
    send(context, .{ .pointer_move = .{ .x = 150, .y = 10 } }, &ids, &out);
    try testing.expectEqual(Hit.none, out[0]);
    send(context, .{ .pointer_move = .{ .x = 50, .y = 10 } }, &ids, &out);
    try testing.expectEqual(Hit.hover_in, out[0]);
}

// Locks the redraw rule: when a redraw moves an area out from under a resting pointer,
// `end_frame` reports that hover must be re-resolved, and an unchanged redraw does not.
test "end_frame reports hover that a redraw moved" {
    const context = new_context();
    const knob = areas.id("knob", 0);
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(0, 0, 50, 50), 0, plain);
    _ = context.end_frame();
    var out: [1]Hit = undefined;
    send(context, .{ .pointer_move = .{ .x = 10, .y = 10 } }, &.{knob}, &out);
    try testing.expectEqual(Hit.hover_in, out[0]);
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(0, 0, 50, 50), 0, plain);
    try testing.expect(!context.end_frame());
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(100, 0, 50, 50), 0, plain);
    try testing.expect(context.end_frame());
    send(context, .{ .pointer_move = .{ .x = 10, .y = 10 } }, &.{knob}, &out);
    try testing.expectEqual(Hit.hover_out, out[0]);
}

// Locks the virtualized list: in a 240 px view of 1,000 rows of 24 px scrolled to 100, only
// rows 4 to 14 emit boxes and areas, the measured content is the whole list, the thumb draws
// with its area, a wheel over a row scrolls the view, and the next frame clamps the offset.
// Locks the wheel of nested views: an inner view whose content fits has `max_scroll` 0 and leaves
// the wheel to the outer view; once its content is 400 px in a 100 px view it keeps the wheel.
test "a view with nothing to scroll leaves the wheel to its parent" {
    const context = new_context();
    const outer_id = areas.id("outer", 0);
    const inner_id = areas.id("inner", 0);
    var outer = ViewState.init();
    var inner = ViewState.init();
    outer.content_h = 1000;
    for ([_]f32{ 50, 400 }) |content| {
        var frame: u32 = 0;
        while (frame < 2) : (frame += 1) {
            context.begin_frame(400, 300, 120);
            const down = flow_of(.down);
            _ = context.begin_view(outer_id, sized(.fill, .{ .fixed = 300 }), down, &outer);
            _ = context.begin_view(inner_id, sized(.fill, .{ .fixed = 100 }), down, &inner);
            context.skip(content);
            context.end_view();
            context.skip(900);
            context.end_view();
            _ = context.end_frame();
        }
        const wheel: input.Event = .{ .wheel = .{ .x = 20, .y = 20, .dx = 0, .dy = 10 } };
        context.event_begin(wheel);
        const want = if (content == 50) outer_id else inner_id;
        try testing.expectEqual(want, context.wheel);
        context.event_end();
    }
    try testing.expectEqual(@as(f32, 300), inner.max_scroll());
}

test "a 1,000-row list emits only visible rows" {
    const context = new_context();
    const list: view.List = .{ .row_height = 24, .count = 1000 };
    const view_id = areas.id("view", 0);
    var state = ViewState.init();
    state.scroll_y = 100;
    state.content_h = list.height();
    var drawn: [2]view.List.Range = undefined;
    var frame: u32 = 0;
    while (frame < 2) : (frame += 1) {
        context.begin_frame(400, 300, 120);
        const walk = sized(.{ .fixed = 200 }, .{ .fixed = 240 });
        const port = context.begin_view(view_id, walk, flow_of(.down), &state);
        const range = list.visible(state.scroll_y, port.height);
        drawn[frame] = range;
        context.skip(@as(f32, @floatFromInt(range.first)) * list.row_height);
        var row = range.first;
        while (row < range.end) : (row += 1) {
            const rect = context.walk(sized(.fill, .{ .fixed = list.row_height }));
            box(context, rect);
            context.area(areas.id("row", row), rect, 0, plain);
        }
        context.skip(@as(f32, @floatFromInt(list.count - range.end)) * list.row_height);
        context.end_view();
        _ = context.end_frame();
        if (frame == 0) {
            try testing.expectEqual(@as(f32, 24000), state.content_h);
            // Eleven rows, one thumb.
            try testing.expectEqual(@as(usize, 12), context.draw.items(draw.Box).len);
            // The view, eleven rows, and the thumb.
            try testing.expectEqual(@as(usize, 13), context.area_list().len);
            const first = context.find(areas.id("row", 4)).?;
            try testing.expectEqualSlices(f32, &.{ 0, -4, 184, 24 }, &first.rect);
            var out: [1]Hit = undefined;
            const wheel: input.Event = .{ .wheel = .{ .x = 20, .y = 10, .dx = 0, .dy = 30000 } };
            context.event_begin(wheel);
            const action = state.handle(context, view_id, wheel);
            try testing.expectEqual(ViewState.Action.scrolled, action);
            out[0] = context.hit(areas.id("row", 4), wheel);
            context.event_end();
            try testing.expectEqual(Hit.hover_in, out[0]);
        }
    }
    try testing.expectEqual(view.List.Range{ .first = 4, .end = 15 }, drawn[0]);
    try testing.expectEqual(@as(f32, 24000 - 240), state.scroll_y);
    try testing.expectEqual(view.List.Range{ .first = 990, .end = 1000 }, drawn[1]);
    try testing.expectEqual(@as(u32, 0), context.area_overflow);
}

fn press_key(key: input.Key, mods: input.Mods) input.Event {
    return .{ .key_down = input.key_press(key, mods, false, "") };
}

fn button_event(x: f32, y: f32, which: input.MouseButton, down: bool) input.Event {
    const sample: input.Button = .{ .x = x, .y = y, .time_ms = 0, .button = which, .mods = .none };
    if (down) return .{ .pointer_down = sample };
    return .{ .pointer_up = sample };
}

const focusable_text: Flags = .{ .wheel = false, .focusable = true, .tab = false, .cursor = .text };

/// Draws three focusable fields at x = 0, 100, 200 and one plain area at x = 300.
fn draw_fields(context: *TestContext) void {
    context.begin_frame(400, 300, 120);
    var index: u32 = 0;
    while (index < 3) : (index += 1) {
        const x: f32 = @floatFromInt(index * 100);
        context.area(areas.id("field", index), rect_at(x, 0, 80, 20), 0, focusable_text);
    }
    context.area(areas.id("plain", 0), rect_at(300, 0, 80, 20), 0, plain);
    _ = context.end_frame();
}

// Locks focus: a left press focuses a focusable area and clears focus elsewhere, Tab and
// Shift+Tab walk the areas in draw order and wrap, the event that moves focus reports
// `focus_lost` and `focus_gained`, Escape clears focus only after the widgets saw it, and an
// undrawn focus survives a draw while Tab restarts from the first area.
test "focus follows presses, Tab cycles in draw order, and Escape clears after routing" {
    const context = new_context();
    draw_fields(context);
    const first = areas.id("field", 0);
    const second = areas.id("field", 1);
    const third = areas.id("field", 2);
    var out: [1]Hit = undefined;
    send(context, button_event(110, 10, .left, true), &.{second}, &out);
    try testing.expect(context.focused(second));
    try testing.expectEqual(@as(f32, 100), context.focused_rect().x);
    send(context, button_event(110, 10, .left, false), &.{second}, &out);
    context.event_begin(press_key(.tab, .none));
    try testing.expect(context.focus_lost(second));
    try testing.expect(context.focus_gained(third));
    context.event_end();
    try testing.expect(context.consumed());
    send(context, press_key(.tab, .none), &.{third}, &out);
    try testing.expect(context.focused(first));
    var shift = input.Mods.none;
    shift.shift = true;
    send(context, press_key(.tab, shift), &.{first}, &out);
    try testing.expect(context.focused(third));
    context.event_begin(press_key(.escape, .none));
    try testing.expect(context.focused(third));
    try testing.expect(!context.focus_lost(third));
    context.event_end();
    try testing.expectEqual(Id.none, context.focus);
    send(context, button_event(10, 10, .left, true), &.{first}, &out);
    send(context, button_event(10, 10, .left, false), &.{first}, &out);
    context.event_begin(button_event(310, 10, .left, true));
    try testing.expect(context.focus_lost(first));
    context.event_end();
    try testing.expectEqual(Id.none, context.focus);
    send(context, button_event(310, 10, .left, false), &.{first}, &out);
    context.event_begin(press_key(.tab, .none));
    context.set_focus(areas.id("gone", 0));
    context.event_end();
    draw_fields(context);
    try testing.expectEqual(areas.id("gone", 0), context.focus);
    send(context, press_key(.tab, .none), &.{first}, &out);
    try testing.expect(context.focused(first));
}

// Locks the `tab` flag: a focused area flagged `tab` keeps focus on Tab and Shift+Tab (its
// widget reads the key, which is consumed), Escape still clears it, and from there Tab cycles
// into the focusable areas again.
test "a tab-flagged focus keeps Tab and Escape still clears it" {
    const context = new_context();
    var editor_flags = focusable_text;
    editor_flags.tab = true;
    const editor = areas.id("editor", 0);
    const field = areas.id("field", 0);
    context.begin_frame(400, 300, 120);
    context.area(field, rect_at(0, 0, 80, 20), 0, focusable_text);
    context.area(editor, rect_at(100, 0, 200, 200), 0, editor_flags);
    _ = context.end_frame();
    var out: [1]Hit = undefined;
    send(context, button_event(150, 50, .left, true), &.{editor}, &out);
    send(context, button_event(150, 50, .left, false), &.{editor}, &out);
    try testing.expect(context.focused(editor));
    context.event_begin(press_key(.tab, .none));
    try testing.expect(!context.focus_lost(editor));
    context.event_end();
    try testing.expect(context.focused(editor));
    try testing.expect(context.consumed());
    var shift = input.Mods.none;
    shift.shift = true;
    send(context, press_key(.tab, shift), &.{editor}, &out);
    try testing.expect(context.focused(editor));
    send(context, press_key(.escape, .none), &.{editor}, &out);
    try testing.expectEqual(Id.none, context.focus);
    send(context, press_key(.tab, .none), &.{editor}, &out);
    try testing.expect(context.focused(field));
    send(context, press_key(.tab, .none), &.{editor}, &out);
    try testing.expect(context.focused(editor));
}

// Locks the browser key verdict: with nothing focusable a Tab is not consumed (the page may
// move focus), a focused widget consumes keys, and Ctrl+C, Ctrl+X, and Ctrl+V are never
// consumed so the page's clipboard events fire.
test "keys are consumed by focus but clipboard shortcuts never are" {
    const context = new_context();
    var out: [1]Hit = undefined;
    const field = areas.id("field", 0);
    send(context, press_key(.tab, .none), &.{field}, &out);
    try testing.expect(!context.consumed());
    draw_fields(context);
    send(context, press_key(.tab, .none), &.{field}, &out);
    try testing.expect(context.consumed());
    send(context, press_key(.a, .none), &.{field}, &out);
    try testing.expect(context.consumed());
    var ctrl = input.Mods.none;
    ctrl.ctrl = true;
    for ([_]input.Key{ .c, .x, .v }) |key| {
        send(context, press_key(key, ctrl), &.{field}, &out);
        try testing.expect(!context.consumed());
    }
    send(context, press_key(.a, ctrl), &.{field}, &out);
    try testing.expect(context.consumed());
    try testing.expectEqual(Hit.none, out[0]);
}

// Locks held keys: presses set and releases clear their bits, and a window blur releases every
// held key and the modifiers.
test "a window blur releases held keys and modifiers" {
    const context = new_context();
    var out: [1]Hit = undefined;
    const ids = [_]Id{areas.id("any", 0)};
    var shift = input.Mods.none;
    shift.shift = true;
    send(context, press_key(.a, shift), &ids, &out);
    send(context, press_key(.left, shift), &ids, &out);
    try testing.expect(context.held(.a));
    try testing.expect(context.held(.left));
    try testing.expect(context.mods.shift);
    send(context, .{ .key_up = input.key_press(.a, shift, false, "") }, &ids, &out);
    try testing.expect(!context.held(.a));
    send(context, .{ .window_focus = false }, &ids, &out);
    try testing.expect(!context.held(.left));
    try testing.expect(!context.mods.shift);
    try testing.expect(!context.window_focused);
    try testing.expectEqual(@as(u64, 0), context.keys_held);
}

// Locks the other buttons: a right press on the hot area is `secondary` without a capture, a
// right release during a left drag does not end it, and the left release does; the drag
// carries the click count.
test "right presses are secondary and never end a left capture" {
    const context = new_context();
    const knob = areas.id("knob", 0);
    const other = areas.id("other", 0);
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(0, 0, 50, 50), 0, plain);
    context.area(other, rect_at(100, 0, 50, 50), 0, plain);
    _ = context.end_frame();
    const ids = [_]Id{ knob, other };
    var out: [2]Hit = undefined;
    send(context, button_event(10, 10, .right, true), &ids, &out);
    try testing.expectEqual(@as(f32, 0), out[0].secondary.rect.x);
    try testing.expectEqual(@as(u8, 1), out[0].secondary.clicks);
    try testing.expectEqual(Id.none, context.capture);
    send(context, button_event(10, 10, .right, false), &ids, &out);
    send(context, button_event(10, 10, .left, true), &ids, &out);
    try testing.expectEqual(knob, context.capture);
    send(context, button_event(120, 10, .right, true), &ids, &out);
    try testing.expectEqual(@as(f32, 120), out[0].drag.x);
    try testing.expectEqual(Hit.none, out[1]);
    send(context, button_event(120, 10, .right, false), &ids, &out);
    try testing.expectEqual(knob, context.capture);
    send(context, button_event(120, 10, .left, false), &ids, &out);
    try testing.expect(!out[0].up.inside);
    try testing.expectEqual(Id.none, context.capture);
}

// Locks the cursor: the hot area's shape, `default` off every area and outside the window,
// and a held `grab` reads `grabbing` until the release.
test "the cursor follows the hot area and a held grab reads grabbing" {
    const context = new_context();
    const knob = areas.id("knob", 0);
    const field = areas.id("field", 0);
    const grab: Flags = .{ .wheel = true, .focusable = false, .tab = false, .cursor = .grab };
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(0, 0, 50, 50), 0, grab);
    context.area(field, rect_at(100, 0, 50, 50), 0, focusable_text);
    _ = context.end_frame();
    var out: [1]Hit = undefined;
    try testing.expectEqual(Cursor.default, context.cursor());
    send(context, .{ .pointer_move = .{ .x = 120, .y = 10 } }, &.{field}, &out);
    try testing.expectEqual(Cursor.text, context.cursor());
    send(context, .{ .pointer_move = .{ .x = 10, .y = 10 } }, &.{field}, &out);
    try testing.expectEqual(Cursor.grab, context.cursor());
    send(context, button_event(10, 10, .left, true), &.{knob}, &out);
    send(context, .{ .pointer_move = .{ .x = 300, .y = 200 } }, &.{knob}, &out);
    try testing.expectEqual(Cursor.grabbing, context.cursor());
    send(context, button_event(300, 200, .left, false), &.{knob}, &out);
    try testing.expectEqual(Cursor.default, context.cursor());
    send(context, .pointer_leave, &.{knob}, &out);
    try testing.expectEqual(Cursor.default, context.cursor());
}

fn press_with(x: f32, y: f32, time_ms: u32, which: input.MouseButton, serial: u32) input.Event {
    return .{ .pointer_down = .{
        .x = x,
        .y = y,
        .time_ms = time_ms,
        .button = which,
        .mods = .none,
        .serial = serial,
    } };
}

/// A bar flagged `drag` at (0, 0, 200, 40), a bottom-right corner at (180, 180, 20, 20), and a
/// plain button on the bar at (10, 10, 20, 20), recorded after it.
fn draw_chrome(context: *TestContext) void {
    const drag: Flags = .{
        .wheel = false,
        .focusable = false,
        .tab = false,
        .cursor = .default,
        .window = .drag,
    };
    const corner: Flags = .{
        .wheel = false,
        .focusable = false,
        .tab = false,
        .cursor = .nwse_resize,
        .window = .bottom_right,
    };
    context.begin_frame(200, 200, 120);
    context.area(areas.id("bar", 0), rect_at(0, 0, 200, 40), 0, drag);
    context.area(areas.id("corner", 0), rect_at(180, 180, 20, 20), 0, corner);
    context.area(areas.id("button", 0), rect_at(10, 10, 20, 20), 0, focusable_text);
    _ = context.end_frame();
}

// Locks section 5a: a press on the drag area requests a move with its serial and captures
// nothing (the button under it is not pressed), a second press within the click interval
// toggles maximize, a corner press resizes from that edge, a right press asks for the window
// menu at the point, and a press on the button over the bar makes no request.
test "a press on a window area becomes the window manager's request" {
    const context = new_context();
    draw_chrome(context);
    const bar = areas.id("bar", 0);
    var out: [1]Hit = undefined;
    send(context, press_with(100, 20, 0, .left, 7), &.{bar}, &out);
    try testing.expectEqual(Hit.hover_in, out[0]);
    try testing.expectEqual(Id.none, context.capture);
    try testing.expectEqual(@as(?WindowRequest, .{ .move = 7 }), context.take_window_request());
    try testing.expectEqual(@as(?WindowRequest, null), context.take_window_request());
    send(context, button_event(100, 20, .left, false), &.{bar}, &out);
    send(context, press_with(101, 21, 100, .left, 8), &.{bar}, &out);
    try testing.expectEqual(@as(?WindowRequest, .toggle_maximize), context.take_window_request());
    send(context, press_with(190, 190, 5000, .left, 9), &.{bar}, &out);
    const resize: WindowRequest = .{ .resize = .{ .edge = .bottom_right, .serial = 9 } };
    try testing.expectEqual(@as(?WindowRequest, resize), context.take_window_request());
    try testing.expectEqual(Cursor.nwse_resize, context.cursor());
    send(context, press_with(150, 30, 9000, .right, 10), &.{bar}, &out);
    const menu: WindowRequest = .{ .menu = .{ .x = 150, .y = 30, .serial = 10 } };
    try testing.expectEqual(@as(?WindowRequest, menu), context.take_window_request());
    send(context, press_with(15, 15, 12000, .left, 11), &.{bar}, &out);
    try testing.expectEqual(@as(?WindowRequest, null), context.take_window_request());
    try testing.expectEqual(areas.id("button", 0), context.capture);
}

// Locks section 5a: `close_requested` leaves `close` for the host unless the app calls
// `keep_open`; the app's own requests are taken once and the last one wins; a `window_state`
// event is stored and owes a draw.
test "a close request closes unless kept open, and the state is stored" {
    const context = new_context();
    try testing.expect(context.window_state().activated);
    try testing.expectEqual(input.Decorations.client, context.window_state().decorations);
    context.event_begin(.close_requested);
    context.event_end();
    try testing.expectEqual(@as(?WindowRequest, .close), context.take_window_request());
    context.event_begin(.close_requested);
    context.keep_open();
    context.event_end();
    try testing.expectEqual(@as(?WindowRequest, null), context.take_window_request());
    context.event_begin(.{ .key_down = input.key_press(.m, .none, false, "m") });
    context.minimize();
    context.toggle_maximize();
    context.event_end();
    try testing.expectEqual(@as(?WindowRequest, .toggle_maximize), context.take_window_request());
    context.dirty = false;
    const state: input.WindowState = .{ .maximized = true, .tiled_left = true };
    context.event_begin(.{ .window_state = state });
    context.event_end();
    try testing.expectEqual(state, context.window_state());
    try testing.expect(context.window_state().snapped());
    try testing.expect(context.dirty);
}

// Locks the clipboard handshake: `copy` keeps the bytes and flags the host once, a copy over
// `clipboard_cap` is cut on a codepoint boundary, and a paste request flags the host once.
test "copy keeps the bytes for the host and cuts on a codepoint boundary" {
    const context = new_context();
    context.event_begin(.{ .frame = 0 });
    context.copy("vco \u{e4}");
    context.request_paste();
    context.event_end();
    try testing.expectEqualStrings("vco \u{e4}", context.copied());
    try testing.expect(context.take_copy());
    try testing.expect(!context.take_copy());
    try testing.expect(context.take_paste_request());
    try testing.expect(!context.take_paste_request());
    const static = struct {
        var long: [clipboard_cap + 1]u8 = undefined;
    };
    @memset(static.long[0 .. clipboard_cap - 1], 'a');
    static.long[clipboard_cap - 1] = 0xC3;
    static.long[clipboard_cap] = 0xA4;
    context.event_begin(.{ .frame = 0 });
    context.copy(&static.long);
    context.event_end();
    try testing.expectEqual(@as(usize, clipboard_cap - 1), context.copied().len);
}

const path_test_draw = [_]draw.DrawType{.{ .type = draw.Path, .cap = 16 }};

const PathTestContext = Context(draw.Context(&path_test_draw, 4, 128), 8);

// Locks that a path area follows its container's alignment shift with its stroke: a 100 px
// row centered in a 400 px window moves by 150, and the pointer resolves to the path near the
// shifted polyline and to nothing in the empty corner of its rect.
test "a path area moves with its container's shift" {
    const static = struct {
        var context: PathTestContext = undefined;
    };
    const context = &static.context;
    context.init();
    context.begin_frame(400, 300, 120);
    var row = flow_of(.right);
    row.alignment = .{ .x = 0.5, .y = 0 };
    _ = context.begin(sized(.fill, .{ .fixed = 100 }), row);
    const cell = context.walk(sized(.{ .fixed = 100 }, .fill));
    const window = context.clip().?;
    const stroke: draw.path.Stroke = .{ .color = .{ 1, 1, 1, 1 }, .width = 4, .hover = 0 };
    const points = [_]draw.Point{
        .{ cell.x, cell.y + 10 },
        .{ cell.x + 90, cell.y + 10 },
        .{ cell.x + 90, cell.y + 90 },
    };
    const placed = draw.path.polyline(context.drawing(), &points, stroke, window).?;
    const cable = areas.id("cable", 0);
    context.path_area(cable, placed, stroke.width, plain);
    _ = context.end();
    _ = context.end_frame();
    const recorded = context.find(cable).?;
    try testing.expectEqual(@as(f32, 150 - 5), recorded.rect[0]);
    try testing.expectEqual(@as(u32, 3), recorded.point_count);
    try testing.expectEqual(@as(f32, 150), context.draw.items(draw.Path)[0].rect[0] + 3);
    context.event_begin(.{ .pointer_move = .{ .x = 150 + 45, .y = 13 } });
    try testing.expectEqual(cable, context.hot);
    context.event_end();
    context.event_begin(.{ .pointer_move = .{ .x = 150 + 20, .y = 80 } });
    try testing.expectEqual(areas.Id.none, context.hot);
    context.event_end();
}

// Locks the timer flag: a fresh context has no timer, setup with a period and `armed` false
// starts stopped, `set_timer` flips it during an event, and a zero period never runs even when
// asked to start armed.
test "the timer flag starts from setup and follows set_timer" {
    const cx = new_context();
    try testing.expectEqual(@as(u32, 0), cx.timer_period_ms);
    try testing.expect(!cx.timer_on);
    cx.timer_setup(33, false);
    try testing.expect(!cx.timer_on);
    cx.event_begin(.{ .frame = 0 });
    cx.set_timer(true);
    try testing.expect(cx.timer_on);
    cx.set_timer(false);
    cx.event_end();
    try testing.expect(!cx.timer_on);
    cx.timer_setup(33, true);
    try testing.expect(cx.timer_on);
    cx.timer_setup(0, true);
    try testing.expect(!cx.timer_on);
    try testing.expectEqual(@as(u32, 0), cx.timer_period_ms);
}

// Locks the audio flag: a fresh context has no source, setup records one stopped, and
// `set_audio` starts and stops it during an event.
test "the audio flag starts stopped and follows set_audio" {
    const cx = new_context();
    try testing.expect(!cx.has_audio);
    try testing.expect(!cx.audio_on);
    cx.audio_setup(true);
    try testing.expect(!cx.audio_on);
    cx.event_begin(.{ .frame = 0 });
    cx.set_audio(true);
    try testing.expect(cx.audio_on);
    cx.event_end();
    cx.event_begin(.{ .frame = 0 });
    cx.set_audio(false);
    cx.event_end();
    try testing.expect(!cx.audio_on);
}

// Locks the theme (section 9b): a fresh context holds `theme.dark` and its record; setting it
// again is a no-op that owes no draw; `theme.light` stores it, writes its record into
// `draw.theme` (its track in slot 2, its background in slot 9), and owes a draw; and the
// scrollbar thumb is drawn in the scheme's `control`.
test "set_theme stores a new scheme and owes a draw, the same one nothing" {
    const cx = new_context();
    const dark_record = theme_module.dark.record();
    try testing.expect(std.meta.eql(theme_module.dark, cx.theme().*));
    const held = std.mem.asBytes(&cx.draw.theme);
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&dark_record), held));
    cx.begin_frame(200, 100, 120);
    _ = cx.end_frame();
    try testing.expect(!cx.dirty);
    cx.event_begin(.{ .frame = 0 });
    cx.set_theme(theme_module.dark);
    try testing.expect(!cx.dirty);
    cx.set_theme(theme_module.light);
    cx.event_end();
    try testing.expect(cx.dirty);
    try testing.expectEqual(theme_module.light.colors.track, cx.draw.theme.track);
    try testing.expectEqual(theme_module.light.colors.background, cx.draw.theme.background);
    try testing.expectEqual(theme_module.light.colors.text, cx.theme().colors.text);
    var state = ViewState.init();
    cx.begin_frame(200, 100, 120);
    const view_id = areas.id("view", 0);
    const port: turtle.Walk = .{ .width = .fill, .height = .{ .fixed = 50 } };
    _ = cx.begin_view(view_id, port, .{ .flow = .down }, &state);
    _ = cx.walk(.{ .width = .fill, .height = .{ .fixed = 400 } });
    cx.end_view();
    _ = cx.end_frame();
    const thumb = cx.draw.items(draw.Box);
    try testing.expectEqual(@as(usize, 1), thumb.len);
    try testing.expectEqual(theme_module.light.colors.control, thumb[0].fill);
}

/// One frame of a 200 by 100 canvas at the top-left with one free module at world
/// (10, 5, 20, 10) and its area, viewed by `state`. Returns the module's world clip.
fn canvas_frame(context: *TestContext, state: *CanvasState) ?Clip {
    context.begin_frame(400, 300, 120);
    const layers = [_]draw.Layer{ @fromBackingInt(1), @fromBackingInt(2) };
    const walk = sized(.{ .fixed = 200 }, .{ .fixed = 100 });
    _ = context.begin_canvas(areas.id("canvas", 0), walk, flow_of(.down), state, &layers);
    const module = rect_at(10, 5, 20, 10);
    const clipped = context.visible(module);
    if (clipped != null) {
        _ = context.begin_at(module, flow_of(.right));
        box(context, module);
        context.area(areas.id("module", 0), module, 0, plain);
        _ = context.end();
    }
    context.end_canvas();
    _ = context.end_frame();
    return clipped;
}

// Locks canvases (section 3a): at zoom 2 from (50, 40) the canvas's clip is the world clip
// (-25, -20)..(75, 30), the cull test runs in world pixels, the module draws at its world rect
// while its area is mapped to (70, 50, 40, 20) on the screen, glyphs zoom inside only, the
// layer comes back, and `begin_at` leaves the canvas cursor where it was.
test "a canvas clips and culls in world pixels and maps its areas to the screen" {
    const context = new_context();
    var state = CanvasState.init(50, 40, 2);
    context.begin_frame(400, 300, 120);
    const layers = [_]draw.Layer{ @fromBackingInt(1), @fromBackingInt(2) };
    const walk = sized(.{ .fixed = 200 }, .{ .fixed = 100 });
    const canvas_id = areas.id("canvas", 0);
    const viewport = context.begin_canvas(canvas_id, walk, flow_of(.down), &state, &layers);
    try testing.expectEqual(rect_at(0, 0, 200, 100), viewport);
    const world: Clip = .{ .x0 = -25, .y0 = -20, .x1 = 75, .y1 = 30 };
    try testing.expectEqual(@as(?Clip, world), context.clip());
    try testing.expectEqual(@as(?Clip, null), context.visible(rect_at(80, 0, 10, 10)));
    try testing.expectEqual(@as(f32, 2), context.draw.text.zoom);
    try testing.expectEqual(@as(f32, 2), context.draw.text.device_scale());
    try testing.expectEqual(@as(u8, 1), @backingInt(context.draw.layer_now));
    const before = context.remaining();
    const module = rect_at(10, 5, 20, 10);
    try testing.expectEqual(module, context.begin_at(module, flow_of(.right)));
    box(context, module);
    context.area(areas.id("module", 0), module, 0, plain);
    try testing.expectEqual(module, context.end());
    try testing.expectEqual(before, context.remaining());
    context.end_canvas();
    try testing.expectEqual(draw.Layer.base, context.draw.layer_now);
    try testing.expectEqual(@as(f32, 1), context.draw.text.zoom);
    _ = context.end_frame();
    try testing.expectEqualSlices(f32, &.{ 10, 5, 20, 10 }, &context.draw.items(draw.Box)[0].rect);
    const drawn = context.draw.items(draw.Box)[0];
    try testing.expectEqualSlices(f32, &.{ -25, -20, 75, 30 }, &drawn.clip);
    const mapped = context.find(areas.id("module", 0)).?;
    try testing.expectEqualSlices(f32, &.{ 70, 50, 40, 20 }, &mapped.rect);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 200, 100 }, &mapped.clip);
    try testing.expectEqual(@as(f32, 2), mapped.zoom);
    try testing.expectEqual(draw.View{ .x = 50, .y = 40, .zoom = 2 }, state.drawn);
}

// Locks exact hit testing at every rung (section 3a): the press at the module's mapped center
// hits it and a point half a logical pixel right of its mapped edge reaches the canvas instead.
test "a canvas area hits its mapped rect at every zoom" {
    const context = new_context();
    const ids = [_]Id{ areas.id("module", 0), areas.id("canvas", 0) };
    var out: [2]Hit = undefined;
    for (canvas.rungs) |rung| {
        var state = CanvasState.init(60, 30, rung);
        if (canvas_frame(context, &state) == null) continue;
        const v = state.drawn;
        const center = v.apply(20, 10);
        const middle: input.Point = .{ .x = center[0], .y = center[1] };
        send(context, .{ .pointer_down = input.left_at(middle) }, &ids, &out);
        try testing.expect(out[0] == .down);
        send(context, .{ .pointer_up = input.left_at(middle) }, &ids, &out);
        const edge = v.apply(30, 10);
        if (edge[0] + 0.5 >= 200) continue;
        const outside: input.Point = .{ .x = edge[0] + 0.5, .y = edge[1] };
        send(context, .{ .pointer_down = input.left_at(outside) }, &ids, &out);
        try testing.expect(out[0] != .down);
        try testing.expect(out[1] == .down);
        send(context, .{ .pointer_up = input.left_at(outside) }, &ids, &out);
    }
}

// Locks the overflow report (section 10): a frame that refuses two instances is reported, the
// same overflow on the next frame is not, a frame without overflow is not but resets the
// memory, and the same overflow after it is reported again.
test "an overflow is reported once per change" {
    const context = new_context();
    try testing.expectEqual(@as(?Overflow, null), context.overflow_report());
    context.draw.overflow_count = 2;
    const two: Overflow = .{ .instances = 2, .areas = 0, .glyphs = 0 };
    try testing.expectEqual(@as(?Overflow, two), context.overflow_report());
    try testing.expectEqual(@as(?Overflow, null), context.overflow_report());
    context.draw.overflow_count = 0;
    try testing.expectEqual(@as(?Overflow, null), context.overflow_report());
    context.draw.overflow_count = 2;
    context.area_overflow = 1;
    const three: Overflow = .{ .instances = 2, .areas = 1, .glyphs = 0 };
    try testing.expectEqual(@as(?Overflow, three), context.overflow_report());
    // A missing icon is reported once, with its face and codepoint, like a refusal.
    context.draw.overflow_count = 0;
    context.area_overflow = 0;
    context.draw.text.miss_icon(3, 0xE13C);
    const icon: Overflow = .{
        .instances = 0,
        .areas = 0,
        .glyphs = 0,
        .icons = 1,
        .icon = 3 << 21 | 0xE13C,
    };
    try testing.expectEqual(@as(?Overflow, icon), context.overflow_report());
    try testing.expectEqual(@as(?Overflow, null), context.overflow_report());
}

/// One frame with a base button at (20, 20, 100, 40) and, when `open`, popup `menu` at
/// (200, 100, 120, 60) holding one row area over its top half; `dim` as in `begin_popup`.
fn popup_frame(context: *TestContext, open: bool, dim: f32) void {
    const menu = areas.id("menu", 0);
    context.begin_frame(400, 300, 120);
    box(context, rect_at(20, 20, 100, 40));
    context.area(areas.id("button", 0), rect_at(20, 20, 100, 40), 0, plain);
    if (open) {
        const rect = rect_at(200, 100, 120, 60);
        const inside = context.begin_popup(menu, rect, .{ .flow = .down }, dim);
        try_expect(context.draw.layer_now == .popup);
        box(context, inside);
        context.area(menu.derive(0), context.walk(sized(.fill, .{ .fixed = 30 })), 0, plain);
        context.end_popup();
    }
    try_expect(context.draw.layer_now == .base);
    _ = context.end_frame();
}

fn try_expect(ok: bool) void {
    assert(ok);
}

// Locks `begin_popup` (section 3c): the backdrop is the first area on the popup layer and
// covers the window, the popup's row follows it on the same layer, the container is the
// popup's rect under the window clip, the layer is restored, and a `dim` of 0.4 appends one
// black face at alpha 0.4 over the window under the popup's face.
test "begin_popup records the backdrop first on the popup layer and restores the layer" {
    const context = new_context();
    const menu = areas.id("menu", 0);
    popup_frame(context, true, 0);
    const list = context.area_list();
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqual(context.popup_backdrop(menu), list[1].id);
    try testing.expectEqual(@as(u8, 6), list[1].layer);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 400, 300 }, &list[1].rect);
    try testing.expectEqual(menu.derive(0), list[2].id);
    try testing.expectEqual(@as(u8, 6), list[2].layer);
    try testing.expectEqualSlices(f32, &.{ 200, 100, 120, 30 }, &list[2].rect);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 400, 300 }, &list[2].clip);
    try testing.expectEqual(@as(usize, 2), context.draw.items(draw.Box).len);
    popup_frame(context, true, 0.4);
    const boxes = context.draw.items(draw.Box);
    try testing.expectEqual(@as(usize, 3), boxes.len);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 400, 300 }, &boxes[1].rect);
    try testing.expectEqual([4]f32{ 0, 0, 0, 0.4 }, boxes[1].fill);
    try testing.expectEqual(draw.Layer.popup, context.draw.layer_at(draw.Box, 1));
    try testing.expectEqual(draw.Layer.popup, context.draw.layer_at(draw.Box, 2));
}

// Locks resolution under a popup (section 3c): a point over the base button resolves to the
// backdrop, a point over the row to the row, and a press outside reaches the backdrop as `down`
// while the button under it sees nothing, then the release gives the button no `up`.
test "a popup's backdrop takes every press outside it" {
    const context = new_context();
    const menu = areas.id("menu", 0);
    const button = areas.id("button", 0);
    const backdrop = context.popup_backdrop(menu);
    popup_frame(context, false, 0);
    var out: [3]Hit = undefined;
    const ids = [_]Id{ button, backdrop, menu.derive(0) };
    send(context, .{ .pointer_move = .{ .x = 50, .y = 30 } }, &ids, &out);
    try testing.expectEqual(Hit.hover_in, out[0]);
    popup_frame(context, true, 0);
    send(context, .{ .pointer_move = .{ .x = 50, .y = 30 } }, &ids, &out);
    try testing.expectEqual(backdrop, context.hot);
    try testing.expectEqual(Hit.hover_out, out[0]);
    try testing.expectEqual(Hit.hover_in, out[1]);
    send(context, .{ .pointer_move = .{ .x = 250, .y = 110 } }, &ids, &out);
    try testing.expectEqual(menu.derive(0), context.hot);
    try testing.expectEqual(Hit.hover_in, out[2]);
    send(context, .{ .pointer_move = .{ .x = 250, .y = 150 } }, &ids, &out);
    try testing.expectEqual(backdrop, context.hot);
    const at: input.Point = .{ .x = 50, .y = 30 };
    send(context, .{ .pointer_down = input.left_at(at) }, &ids, &out);
    try testing.expect(out[1] == .down);
    try testing.expectEqual(Hit.none, out[0]);
    // The owner dismisses and the next frame has no popup; the release still ends the
    // backdrop's capture, so the button gets no click.
    popup_frame(context, false, 0);
    send(context, .{ .pointer_up = input.left_at(at) }, &ids, &out);
    try testing.expect(out[1] == .up);
    try testing.expect(out[0] != .up);
    try testing.expectEqual(Id.none, context.capture);
}

// Locks the request check's bookkeeping (section 3c): a request is met by `begin_popup` or
// `skip_popup` in the next draw and cleared there, so the frame after owes nothing.
test "a popup request is met by the next draw" {
    const context = new_context();
    const menu = areas.id("menu", 0);
    popup_frame(context, false, 0);
    context.event_begin(.{ .frame = 0 });
    context.request_popup(menu);
    context.event_end();
    try testing.expect(context.dirty);
    try testing.expectEqual(menu, context.popup_requested);
    popup_frame(context, true, 0);
    try testing.expectEqual(Id.none, context.popup_requested);
    context.event_begin(.{ .frame = 0 });
    context.request_popup(menu);
    context.event_end();
    context.begin_frame(400, 300, 120);
    context.skip_popup(menu);
    _ = context.end_frame();
    try testing.expectEqual(Id.none, context.popup_requested);
}

/// Dispatches the file-drag `event` and writes what it means for each of `ids` into `out`.
fn send_drop(context: *TestContext, event: input.Event, ids: []const Id, out: []DropHit) void {
    assert(ids.len == out.len);
    context.event_begin(event);
    for (ids, out) |key, *result| result.* = context.drop_hit(key, event);
    context.event_end();
}

// Locks the drop target (section 7a): two zones side by side get drop_in and drop_out as the
// drag crosses them, a plain area answers nothing, `hit` answers none and the pointer, hover,
// and capture stay, a leave ends the target, and a drop carries the zone's rect and clears it.
test "a file drag crosses two zones and drops on the second" {
    const context = new_context();
    const left = areas.id("zone", 0);
    const right = areas.id("zone", 1);
    const label = areas.id("label", 0);
    context.begin_frame(400, 300, 120);
    context.area(left, rect_at(0, 0, 100, 100), 0, drop_flag);
    context.area(right, rect_at(200, 0, 100, 100), 0, drop_flag);
    context.area(label, rect_at(220, 20, 40, 20), 0, plain);
    _ = context.end_frame();
    const ids = [_]Id{ left, right, label };
    var out: [3]DropHit = undefined;
    send_drop(context, .{ .drop_over = .{ .x = 50, .y = 50 } }, &ids, &out);
    try testing.expectEqual(DropHit.drop_in, out[0]);
    try testing.expectEqual(DropHit.none, out[1]);
    try testing.expect(context.drop_hovering(left));
    try testing.expect(context.drop_wanted());
    send_drop(context, .{ .drop_over = .{ .x = 60, .y = 50 } }, &ids, &out);
    try testing.expectEqual(DropHit.none, out[0]);
    send_drop(context, .{ .drop_over = .{ .x = 230, .y = 30 } }, &ids, &out);
    try testing.expectEqual(DropHit.drop_out, out[0]);
    try testing.expectEqual(DropHit.drop_in, out[1]);
    try testing.expectEqual(DropHit.none, out[2]);
    context.event_begin(.{ .drop_over = .{ .x = 230, .y = 30 } });
    try testing.expectEqual(Hit.none, context.hit(label, .{ .drop_over = .{ .x = 230, .y = 30 } }));
    context.event_end();
    try testing.expect(!context.pointer.inside);
    try testing.expectEqual(Id.none, context.hover);
    send_drop(context, .drop_leave, &ids, &out);
    try testing.expectEqual(DropHit.drop_out, out[1]);
    try testing.expect(!context.drop_wanted());
    var files: input.Drop = .{ .x = 250, .y = 50, .count = 2, .skipped = 0, .files = undefined };
    send_drop(context, .{ .drop = &files }, &ids, &out);
    try testing.expectEqual(@as(f32, 200), out[1].dropped.rect.x);
    try testing.expectEqual(@as(f32, 250), out[1].dropped.x);
    try testing.expectEqual(&files, out[1].dropped.files);
    try testing.expectEqual(DropHit.none, out[0]);
    try testing.expect(!context.drop_hovering(right));
    files.x = 350;
    send_drop(context, .{ .drop = &files }, &ids, &out);
    try testing.expectEqual(DropHit.none, out[1]);
}

// Locks the accept and cancel handshake (section 7a): the accepting id receives the chunks and
// no other id does, the host takes the mask once, and cancels gather until the host takes them.
test "accept_files names the receiver and the host takes accept and cancel once" {
    const context = new_context();
    const zone = areas.id("zone", 0);
    const other = areas.id("zone", 1);
    context.begin_frame(400, 300, 120);
    context.area(zone, rect_at(0, 0, 100, 100), 0, drop_flag);
    _ = context.end_frame();
    const files: input.Drop = .{ .x = 10, .y = 10, .count = 3, .skipped = 0, .files = undefined };
    const event: input.Event = .{ .drop = &files };
    context.event_begin(event);
    switch (context.drop_hit(zone, event)) {
        .dropped => context.accept_files(zone, 0b101),
        else => return error.TestUnexpectedResult,
    }
    context.event_end();
    try testing.expectEqual(@as(?u16, 0b101), context.take_files_accept());
    try testing.expectEqual(@as(?u16, null), context.take_files_accept());
    const chunk: input.Chunk = .{ .file = 0, .offset = 0, .bytes = "abc", .end = .more };
    var out: [2]DropHit = undefined;
    send_drop(context, .{ .file = &chunk }, &.{ zone, other }, &out);
    try testing.expectEqual(&chunk, out[0].file);
    try testing.expectEqual(DropHit.none, out[1]);
    context.event_begin(.{ .file = &chunk });
    context.cancel_files(0b001);
    context.cancel_files(0b100);
    context.event_end();
    try testing.expectEqual(@as(u16, 0b101), context.take_files_cancel());
    try testing.expectEqual(@as(u16, 0), context.take_files_cancel());
}

const drag_source_id = areas.id("drag source", 0);
const drag_a = areas.id("drag target", 0);
const drag_b = areas.id("drag target", 1);

/// Draws a plain source at (0, 0, 50, 30) and two drag targets, A at (100, 0, 100, 100) and B
/// at (250, 0, 100, 100); with `cover`, a popup-layer area over A.
fn drag_frame(context: *TestContext, cover: bool) void {
    context.begin_frame(400, 300, 120);
    context.area(drag_source_id, rect_at(0, 0, 50, 30), 0, plain);
    context.area(drag_a, rect_at(100, 0, 100, 100), 0, drag_target_flag);
    context.area(drag_b, rect_at(250, 0, 100, 100), 0, drag_target_flag);
    if (cover) {
        const previous = context.drawing().layer(.popup);
        context.area(areas.id("drag cover", 0), rect_at(90, 0, 120, 120), 0, plain);
        _ = context.drawing().layer(previous);
    }
    _ = context.end_frame();
}

/// Dispatches `event` and writes what it means for the source and A and B as drag hits, and
/// for the source as a plain hit.
fn send_drag(context: *TestContext, event: input.Event, out: *[3]DragHit) Hit {
    context.event_begin(event);
    const ids = [_]Id{ drag_source_id, drag_a, drag_b };
    for (ids, out) |key, *result| result.* = context.drag_hit(key, event);
    const source = context.hit(drag_source_id, event);
    context.event_end();
    return source;
}

/// Presses the source at (10, 10), then moves to (20, 10) and begins a drag of `payload`
/// there, as a widget does on its `drag` hit.
fn begin_drag(context: *TestContext, payload: u64) !void {
    var out: [3]DragHit = undefined;
    _ = send_drag(context, button_event(10, 10, .left, true), &out);
    try testing.expectEqual(drag_source_id, context.capture);
    const move: input.Event = .{ .pointer_move = .{ .x = 20, .y = 10 } };
    context.event_begin(move);
    try testing.expect(context.hit(drag_source_id, move) == .drag);
    context.drag_begin(drag_source_id, payload);
    try testing.expectEqual(DragHit.none, context.drag_hit(drag_a, move));
    context.event_end();
    try testing.expectEqual(drag_source_id, context.dragging().?.source);
}

fn move_to(x: f32, y: f32) input.Event {
    return .{ .pointer_move = .{ .x = x, .y = y } };
}

// Locks a drag between widgets (section 7b): onto A is drag_in with the pointer, A's rect,
// and the payload; a move on A is over; onto B is drag_out for A and drag_in for B; each
// pointer event owes a draw; the release is dropped for B and ended { B } for the source,
// whose plain hit is still its capture's up, and the session and the capture are over.
test "a drag between widgets crosses two targets and drops on the second" {
    const context = new_context();
    drag_frame(context, false);
    try begin_drag(context, 42);
    var out: [3]DragHit = undefined;
    context.dirty = false;
    try testing.expect(send_drag(context, move_to(150, 50), &out) == .drag);
    try testing.expect(context.dirty);
    try testing.expectEqual(@as(f32, 150), out[1].drag_in.x);
    try testing.expectEqual(@as(f32, 100), out[1].drag_in.rect.x);
    try testing.expectEqual(@as(u64, 42), out[1].drag_in.payload);
    try testing.expectEqual(drag_source_id, out[1].drag_in.source);
    try testing.expectEqual(DragHit.none, out[0]);
    try testing.expectEqual(DragHit.none, out[2]);
    _ = send_drag(context, move_to(160, 50), &out);
    try testing.expectEqual(@as(f32, 160), out[1].over.x);
    _ = send_drag(context, move_to(300, 50), &out);
    try testing.expectEqual(DragHit.drag_out, out[1]);
    try testing.expectEqual(@as(f32, 250), out[2].drag_in.rect.x);
    const released = send_drag(context, button_event(310, 60, .left, false), &out);
    try testing.expect(!released.up.inside);
    try testing.expectEqual(DragEnd{ .target = drag_b, .cancelled = false }, out[0].ended);
    try testing.expectEqual(@as(f32, 310), out[2].dropped.x);
    try testing.expectEqual(@as(u64, 42), out[2].dropped.payload);
    try testing.expectEqual(DragHit.none, out[1]);
    try testing.expectEqual(@as(?Dragging, null), context.dragging());
    try testing.expectEqual(Id.none, context.capture);
}

// Locks the cancels (section 7b): Escape over A gives A drag_out and the source ended
// { none, cancelled }, clears focus as always, and keeps the capture, so the release is a
// plain up with no drop; a pointer leave cancels and ends the capture in the same event.
test "Escape and a leave cancel a drag between widgets" {
    const context = new_context();
    drag_frame(context, false);
    try begin_drag(context, 7);
    var out: [3]DragHit = undefined;
    _ = send_drag(context, move_to(150, 50), &out);
    _ = send_drag(context, press_key(.escape, .none), &out);
    try testing.expectEqual(DragHit.drag_out, out[1]);
    try testing.expectEqual(DragEnd{ .target = .none, .cancelled = true }, out[0].ended);
    try testing.expectEqual(@as(?Dragging, null), context.dragging());
    try testing.expectEqual(drag_source_id, context.capture);
    try testing.expectEqual(Id.none, context.focus);
    const released = send_drag(context, button_event(150, 50, .left, false), &out);
    try testing.expect(released == .up);
    for (out) |result| try testing.expectEqual(DragHit.none, result);
    drag_frame(context, false);
    try begin_drag(context, 8);
    _ = send_drag(context, move_to(150, 50), &out);
    _ = send_drag(context, .pointer_leave, &out);
    try testing.expectEqual(DragHit.drag_out, out[1]);
    try testing.expect(out[0].ended.cancelled);
    try testing.expectEqual(@as(?Dragging, null), context.dragging());
    try testing.expectEqual(Id.none, context.capture);
}

// Locks the queries and the layer rule (section 7b): while a drag is in flight the cursor is
// grabbing, `dragging()` follows the pointer and names the target, `drag_hovering` is true
// for A only while over it; a popup-layer area over A hides it, so the release drops on
// nothing and the source's ended names no target.
test "a drag reads grabbing, reports its target, and a popup blocks it" {
    const context = new_context();
    drag_frame(context, false);
    try begin_drag(context, 1);
    var out: [3]DragHit = undefined;
    try testing.expectEqual(Cursor.grabbing, context.cursor());
    _ = send_drag(context, move_to(120, 40), &out);
    const now = context.dragging().?;
    try testing.expectEqual(@as(f32, 120), now.x);
    try testing.expectEqual(drag_a, now.target);
    try testing.expect(context.drag_hovering(drag_a));
    try testing.expect(!context.drag_hovering(drag_b));
    _ = send_drag(context, move_to(220, 40), &out);
    try testing.expect(!context.drag_hovering(drag_a));
    _ = send_drag(context, button_event(220, 40, .left, false), &out);
    drag_frame(context, true);
    try begin_drag(context, 2);
    _ = send_drag(context, move_to(150, 50), &out);
    try testing.expectEqual(DragHit.none, out[1]);
    try testing.expect(!context.drag_hovering(drag_a));
    _ = send_drag(context, button_event(150, 50, .left, false), &out);
    try testing.expectEqual(DragEnd{ .target = .none, .cancelled = false }, out[0].ended);
    try testing.expectEqual(DragHit.none, out[1]);
}

// ------------------------------------------------------------------------------- touch tests

const pad_count: u32 = 12;

fn pad(index: u32) Id {
    return areas.id("pad", index);
}

/// Twelve pads in a row, 30 px wide at x = 35 * index and 30 tall, and a focusable field below.
fn draw_pads(context: *TestContext, flags: Flags) void {
    context.begin_frame(600, 300, 120);
    var index: u32 = 0;
    while (index < pad_count) : (index += 1) {
        const x: f32 = @floatFromInt(index * 35);
        context.area(pad(index), rect_at(x, 0, 30, 30), 0, flags);
    }
    context.area(areas.id("field", 0), rect_at(0, 100, 80, 20), 0, focusable_text);
    _ = context.end_frame();
}

fn touch_down(id: u32, x: f32, y: f32) input.Event {
    return .{ .touch_down = .{ .id = id, .x = x, .y = y, .time_ms = 0, .serial = id + 100 } };
}

fn touch_move(id: u32, x: f32, y: f32) input.Event {
    return .{ .touch_move = .{ .id = id, .x = x, .y = y, .time_ms = 0 } };
}

fn touch_up(id: u32) input.Event {
    return .{ .touch_up = .{ .id = id, .time_ms = 0 } };
}

/// What `touch` made of each pointer event of a touch event: its hits for pad 0 to 11 in
/// `hits[event][pad]`, and how many pointer events there were. Null when the event was for no
/// contact.
const TouchResult = struct {
    hits: [2][pad_count]Hit,
    count: u32,
};

/// Dispatches `event` as `ui.dispatch` does and records every pad's hit.
fn touch(context: *TestContext, event: input.Event) ?TouchResult {
    // A down of an id still live cancels it first, as `ui.dispatch` does.
    if (event == .touch_down and context.touch_live(event.touch_down.id)) {
        _ = touch(context, .{ .touch_cancel = event.touch_down.id });
    }
    if (event == .touch_cancel and event.touch_cancel == null) {
        var ids: [input.contact_cap]u32 = undefined;
        const count = context.touch_ids(&ids);
        for (ids[0..count]) |contact_id| _ = touch(context, .{ .touch_cancel = contact_id });
        return null;
    }
    const plan = context.touch_begin(event) orelse return null;
    var result: TouchResult = .{ .hits = undefined, .count = plan.count };
    for (plan.events[0..plan.count], 0..) |pointer_event, slot| {
        context.event_begin(pointer_event);
        for (&result.hits[slot], 0..) |*out, index| {
            out.* = context.hit(pad(@intCast(index)), pointer_event);
        }
        context.event_end();
    }
    context.touch_end();
    return result;
}

fn mouse_state(context: *const TestContext) PointerSlot {
    var state: PointerSlot = undefined;
    inline for (@typeInfo(PointerSlot).@"struct".field_names) |name| {
        @field(state, name) = @field(context, name);
    }
    return state;
}

// Locks a chord: ten fingers on ten pads claim ten contacts, the first primary, each pad gets
// its own down, all ten are captured at once, each lifts with an up inside, and the table is
// empty again with the most seen recorded.
test "ten fingers claim ten contacts and free them" {
    const context = new_context();
    draw_pads(context, plain);
    var finger: u32 = 0;
    while (finger < 10) : (finger += 1) {
        const x: f32 = @floatFromInt(finger * 35 + 10);
        const result = touch(context, touch_down(finger, x, 10)).?;
        try testing.expect(result.hits[0][finger] == .down);
        try testing.expectEqual(finger + 1, context.contacts_live());
    }
    try testing.expectEqual(@as(u32, 10), context.contacts_most);
    for (context.contacts[0..10], 0..) |contact, index| {
        try testing.expectEqual(pad(@intCast(index)), contact.slot.capture);
        try testing.expectEqual(index == 0, contact.primary);
    }
    finger = 0;
    while (finger < 10) : (finger += 1) {
        const x: f32 = @floatFromInt(finger * 35 + 12);
        const moved = touch(context, touch_move(finger, x, 12)).?;
        try testing.expect(moved.hits[0][finger] == .drag);
        const lifted = touch(context, touch_up(finger)).?;
        try testing.expect(lifted.hits[0][finger].up.inside);
        try testing.expect(lifted.hits[1][finger] == .hover_out);
    }
    try testing.expectEqual(@as(u32, 0), context.contacts_live());
    try testing.expectEqual(@as(u32, 0), context.contacts_refused);
}

// Locks the table's cap: a 17th contact is counted and its later events do nothing, the others
// are untouched, and a freed slot takes the next finger.
test "a seventeenth contact is refused and counted" {
    const context = new_context();
    draw_pads(context, plain);
    var finger: u32 = 0;
    while (finger < input.contact_cap) : (finger += 1) {
        const x: f32 = @floatFromInt(finger % 12 * 35 + 10);
        _ = touch(context, touch_down(finger, x, 10)).?;
    }
    try testing.expectEqual(input.contact_cap, context.contacts_live());
    try testing.expectEqual(@as(?TouchResult, null), touch(context, touch_down(99, 10, 10)));
    try testing.expectEqual(@as(u32, 1), context.contacts_refused);
    try testing.expectEqual(@as(?TouchResult, null), touch(context, touch_move(99, 20, 10)));
    try testing.expectEqual(@as(?TouchResult, null), touch(context, touch_up(99)));
    try testing.expectEqual(input.contact_cap, context.contacts_live());
    _ = touch(context, touch_up(3)).?;
    try testing.expect(touch(context, touch_down(98, 150, 10)) != null);
    try testing.expectEqual(input.contact_cap, context.contacts_live());
}

// Locks a repeated down: id 4 still down (its up was dropped) is cancelled by the next down of
// 4, which gets a fresh contact on another pad, so one contact holds id 4 and the old pad's
// capture is gone.
test "a down of a live id cancels the stale contact" {
    const context = new_context();
    draw_pads(context, plain);
    _ = touch(context, touch_down(4, 10, 10)).?;
    try testing.expectEqual(pad(0), context.contacts[0].slot.capture);
    const result = touch(context, touch_down(4, 45, 10)).?;
    try testing.expect(result.hits[0][1] == .down);
    try testing.expectEqual(@as(u32, 1), context.contacts_live());
    try testing.expect(!context.holds(pad(0)));
    try testing.expect(context.holds(pad(1)));
}

// Locks capture: a finger that moves off its pad keeps it (a drag, then an up with inside =
// false), and nothing else sees the move; another pad gets nothing.
test "a finger keeps its pad when it leaves it" {
    const context = new_context();
    draw_pads(context, plain);
    _ = touch(context, touch_down(0, 10, 10)).?;
    const moved = touch(context, touch_move(0, 200, 200)).?;
    try testing.expect(moved.hits[0][0] == .drag);
    for (moved.hits[0][1..]) |other| try testing.expect(other == .none);
    const lifted = touch(context, touch_up(0)).?;
    try testing.expect(!lifted.hits[0][0].up.inside);
    try testing.expectEqual(@as(u32, 2), lifted.count);
    try testing.expectEqual(Id.none, context.capture);
}

// Locks cancel: the leave gives the capture up { inside = false } and no other hit, `null`
// cancels every contact, and a cancel of an unknown id is ignored.
test "cancel ends a press without a click" {
    const context = new_context();
    draw_pads(context, plain);
    _ = touch(context, touch_down(0, 10, 10)).?;
    _ = touch(context, touch_down(1, 45, 10)).?;
    const one = touch(context, .{ .touch_cancel = 0 }).?;
    try testing.expect(!one.hits[0][0].up.inside);
    try testing.expectEqual(@as(u32, 1), one.count);
    try testing.expectEqual(@as(u32, 1), context.contacts_live());
    try testing.expectEqual(@as(?TouchResult, null), touch(context, .{ .touch_cancel = 77 }));
    _ = touch(context, .{ .touch_cancel = null });
    try testing.expectEqual(@as(u32, 0), context.contacts_live());
    try testing.expect(!context.holds(pad(1)));
}

// Locks the primary rules: the first finger is primary and a second is not; lifting the first
// leaves a later finger non-primary while another is down; a finger that lands alone after every
// lift is primary again; and only the primary moves focus.
test "only the first contact is primary and moves focus" {
    const context = new_context();
    draw_pads(context, plain);
    context.focus = pad(5);
    _ = touch(context, touch_down(0, 10, 10)).?;
    try testing.expect(context.contacts[0].primary);
    try testing.expectEqual(Id.none, context.focus);
    context.focus = areas.id("field", 0);
    _ = touch(context, touch_down(1, 45, 10)).?;
    try testing.expect(!context.contacts[1].primary);
    try testing.expectEqual(areas.id("field", 0), context.focus);
    _ = touch(context, touch_up(0)).?;
    _ = touch(context, touch_down(2, 80, 10)).?;
    try testing.expect(!context.contacts[0].primary);
    _ = touch(context, touch_up(1)).?;
    _ = touch(context, touch_up(2)).?;
    _ = touch(context, touch_down(3, 10, 10)).?;
    try testing.expect(context.contacts[0].primary);
}

// Locks a second finger on a held area: its press is not a down for the pad, the contact holds
// nothing, hot and hover are cleared, `target` still names the pad and `joined` is true, and
// its moves and lift resolve nothing; the first finger still owns the pad.
test "a second finger on a held pad is joined and sees nothing" {
    const context = new_context();
    draw_pads(context, plain);
    _ = touch(context, touch_down(0, 10, 10)).?;
    const second = touch(context, touch_down(1, 20, 20)).?;
    for (second.hits[0]) |value| try testing.expect(value == .none);
    try testing.expectEqual(Id.none, context.contacts[1].slot.capture);
    try testing.expectEqual(pad(0), context.contacts[1].target);
    try testing.expect(context.contacts[1].joined);
    try testing.expectEqual(Id.none, context.contacts[1].slot.hover);
    const moved = touch(context, touch_move(1, 22, 22)).?;
    for (moved.hits[0]) |value| try testing.expect(value == .none);
    const lifted = touch(context, touch_up(1)).?;
    for (lifted.hits[0]) |value| try testing.expect(value == .none);
    try testing.expectEqual(pad(0), context.contacts[0].slot.capture);
    const first = touch(context, touch_move(0, 12, 12)).?;
    try testing.expect(first.hits[0][0] == .drag);
}

// Locks `primary_only`: a non-primary contact's press on such an area gives widgets nothing and
// leaves `target` at `.none`; the primary contact, and the mouse, press it as ever.
test "primary_only hides an area from a second finger" {
    const context = new_context();
    var flags = plain;
    flags.primary_only = true;
    draw_pads(context, flags);
    _ = touch(context, touch_down(0, 10, 10)).?;
    const second = touch(context, touch_down(1, 45, 10)).?;
    for (second.hits[0]) |value| try testing.expect(value == .none);
    try testing.expectEqual(Id.none, context.contacts[1].target);
    try testing.expect(!context.contacts[1].joined);
    try testing.expectEqual(pad(0), context.contacts[0].slot.capture);
    var out: [1]Hit = undefined;
    send(context, button_event(80, 10, .left, true), &.{pad(2)}, &out);
    try testing.expect(out[0] == .down);
}

// Locks the mouse beside the fingers: with two fingers down and moving, the mouse's own state
// (pointer, hot, hover, capture, press flags) is exactly what it was before them, and a mouse
// press on a third pad works in between.
test "the mouse's pointer state is the same after any touch dispatch" {
    const context = new_context();
    draw_pads(context, plain);
    var out: [1]Hit = undefined;
    send(context, move_to(100, 10), &.{pad(2)}, &out);
    const before = mouse_state(context);
    _ = touch(context, touch_down(0, 10, 10)).?;
    _ = touch(context, touch_down(1, 45, 10)).?;
    _ = touch(context, touch_move(0, 15, 12)).?;
    try testing.expectEqual(before, mouse_state(context));
    send(context, button_event(100, 10, .left, true), &.{pad(2)}, &out);
    try testing.expect(out[0] == .down);
    try testing.expectEqual(pad(2), context.capture);
    _ = touch(context, touch_move(1, 50, 12)).?;
    try testing.expectEqual(pad(2), context.capture);
    try testing.expect(context.holds(pad(0)) and context.holds(pad(1)) and context.holds(pad(2)));
    send(context, button_event(100, 10, .left, false), &.{pad(2)}, &out);
    try testing.expect(out[0].up.inside);
    try testing.expectEqual(pad(0), context.contacts[0].slot.capture);
    try testing.expect(context.touch() == null);
}

// Locks a press on the mouse's pad: a finger landing on the area the mouse holds is joined.
test "a finger on the mouse's pad is joined" {
    const context = new_context();
    draw_pads(context, plain);
    var out: [1]Hit = undefined;
    send(context, button_event(10, 10, .left, true), &.{pad(0)}, &out);
    const result = touch(context, touch_down(0, 12, 12)).?;
    for (result.hits[0]) |value| try testing.expect(value == .none);
    try testing.expect(context.contacts[0].joined);
    try testing.expectEqual(pad(0), context.capture);
}

// Locks double taps: two contacts within 400 ms and 12 px count 2, a third within it 3, one
// farther than 12 px restarts at 1, and the mouse's slop of 4 px does not apply.
test "taps count with the finger slop" {
    const context = new_context();
    draw_pads(context, plain);
    var now: u32 = 1000;
    var counts: [4]u8 = undefined;
    const xs = [_]f32{ 10, 20, 28, 45 };
    for (xs, &counts, 0..) |x, *count, id| {
        const plan = touch(context, .{ .touch_down = .{
            .id = @intCast(id),
            .x = x,
            .y = 10,
            .time_ms = now,
        } });
        _ = plan.?;
        count.* = context.touch_clicks.count;
        _ = touch(context, touch_up(@intCast(id))).?;
        now += 100;
    }
    try testing.expectEqual([4]u8{ 1, 2, 3, 1 }, counts);
}

// Locks `touch()`: during a finger's dispatch it names the contact, its phase, origin, and
// target; outside one it is null.
test "touch names the finger during its dispatch" {
    const context = new_context();
    draw_pads(context, plain);
    try testing.expect(context.touch() == null);
    const plan = context.touch_begin(touch_down(7, 40, 10)).?;
    context.event_begin(plan.events[0]);
    const info = context.touch().?;
    try testing.expectEqual(@as(u32, 7), info.id);
    try testing.expect(info.primary);
    try testing.expectEqual(TouchPhase.down, info.phase);
    try testing.expectEqual(pad(1), info.target);
    try testing.expectEqual([2]f32{ 40, 10 }, info.origin);
    context.event_end();
    context.touch_end();
    try testing.expect(context.touch() == null);
}

// Locks a layout change: a scroll that moves the held pad moves the contact's capture rect at
// `end_frame`, as for the mouse's.
test "end_frame refreshes every contact's capture rect" {
    const context = new_context();
    draw_pads(context, plain);
    _ = touch(context, touch_down(0, 10, 10)).?;
    context.begin_frame(600, 300, 120);
    context.area(pad(0), rect_at(0, 50, 30, 30), 0, plain);
    _ = context.end_frame();
    try testing.expectEqual(@as(f32, 50), context.contacts[0].slot.capture_rect.y);
}

/// A drag session of source `pad(0)` begun by a finger: the press on pad 0, then a move that
/// the widget answers with `drag_begin`.
fn finger_drag(context: *TestContext, id: u32) !void {
    _ = touch(context, touch_down(id, 10, 10)).?;
    const plan = context.touch_begin(touch_move(id, 20, 10)).?;
    context.event_begin(plan.events[0]);
    context.drag_begin(pad(0), 5);
    context.event_end();
    context.touch_end();
}

// Locks the drag session's owner (section 7b): a drag begun by the primary finger runs, other
// fingers' events during it change nothing and trip no assert, the mouse can press elsewhere,
// and the primary's lift ends it; a non-primary finger's `drag_begin` does nothing.
test "a drag between widgets belongs to the primary contact" {
    const context = new_context();
    draw_pads(context, drag_target_flag);
    try finger_drag(context, 0);
    try testing.expectEqual(pad(0), context.dragging().?.source);
    try testing.expectEqual(@as(?u32, 0), context.drag_owner);
    _ = touch(context, touch_down(1, 80, 10)).?;
    _ = touch(context, touch_move(1, 85, 10)).?;
    try testing.expectEqual(pad(0), context.dragging().?.source);
    var out: [1]Hit = undefined;
    send(context, button_event(150, 10, .left, true), &.{pad(4)}, &out);
    try testing.expect(out[0] == .down);
    try testing.expectEqual(pad(0), context.dragging().?.source);
    _ = touch(context, touch_move(0, 115, 10)).?;
    try testing.expectEqual(pad(3), context.dragging().?.target);
    _ = touch(context, touch_up(0)).?;
    try testing.expect(context.dragging() == null);
    _ = touch(context, touch_up(1)).?;
    send(context, button_event(150, 10, .left, false), &.{pad(4)}, &out);
    // A second finger cannot begin one.
    _ = touch(context, touch_down(2, 10, 10)).?;
    _ = touch(context, touch_down(3, 45, 10)).?;
    const plan = context.touch_begin(touch_move(3, 50, 10)).?;
    context.event_begin(plan.events[0]);
    context.drag_begin(pad(1), 9);
    context.event_end();
    context.touch_end();
    try testing.expect(context.dragging() == null);
}

// Locks the swap's completeness: every field of `PointerSlot` exists on the context with the
// same type, so a field renamed on one side fails to compile, and the slot fields are the
// pointer's: no field of the mouse's pointer state sits outside it.
test "PointerSlot names context fields of the same types" {
    inline for (@typeInfo(PointerSlot).@"struct".field_names) |name| {
        try testing.expect(@hasField(TestContext, name));
    }
    try testing.expectEqual(@as(usize, 15), @typeInfo(PointerSlot).@"struct".field_names.len);
}
