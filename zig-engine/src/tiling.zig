const std = @import("std");
const geometry = @import("geometry.zig");
const bsp = @import("bsp.zig");
const workspace = @import("workspace.zig");
const constraints = @import("constraints.zig");

pub const Rect = geometry.Rect;
pub const GapConfig = geometry.GapConfig;
pub const WindowId = bsp.WindowId;
pub const Direction = bsp.Direction;
pub const LayoutMode = bsp.LayoutMode;
pub const SwitchCounts = workspace.SwitchCounts;

var global_workspaces: workspace.WorkspaceManager = undefined;
var global_gaps: GapConfig = GapConfig{};
var global_mins: constraints.MinSizes = .{};
var is_initialized: bool = false;

pub export fn talys_engine_init() void {
    global_workspaces = workspace.WorkspaceManager.init();
    global_gaps = GapConfig{};
    global_mins.reset();
    is_initialized = true;
}

pub export fn talys_engine_reset() void {
    if (!is_initialized) talys_engine_init();
    global_workspaces.reset();
    global_mins.reset();
}

pub export fn talys_engine_set_gaps(inner: f64, outer: f64) void {
    global_gaps.inner = inner;
    global_gaps.outer = outer;
}

pub export fn talys_engine_add_window(wid: WindowId) void {
    if (!is_initialized) talys_engine_init();
    global_workspaces.addWindow(wid);
}

pub export fn talys_engine_add_window_to_workspace(wid: WindowId, target_ws: u8) void {
    if (!is_initialized) talys_engine_init();
    global_workspaces.addWindowToWorkspace(wid, target_ws);
}

pub export fn talys_engine_remove_window(wid: WindowId) void {
    if (!is_initialized) return;
    global_workspaces.removeWindow(wid);
    global_mins.remove(wid);
}

/// Smallest size the window's app accepts; layouts size tiles to fit it where they can.
pub export fn talys_engine_set_min_size(wid: WindowId, width: f64, height: f64) void {
    if (!is_initialized) talys_engine_init();
    global_mins.set(wid, .{ .width = width, .height = height });
}

pub export fn talys_engine_has_window(wid: WindowId) bool {
    if (!is_initialized) return false;
    return global_workspaces.hasWindow(wid);
}

pub export fn talys_engine_set_focus(wid: WindowId) void {
    if (!is_initialized) return;
    global_workspaces.getActiveEngine().setFocus(wid);
}

pub export fn talys_engine_get_focus() WindowId {
    if (!is_initialized) return 0;
    return global_workspaces.getActiveEngine().getFocus() orelse 0;
}

pub export fn talys_engine_focus_direction(direction: u8, screen_rect: Rect) WindowId {
    if (!is_initialized) return 0;
    if (direction > 3) return 0;
    const dir: Direction = @enumFromInt(direction);
    return global_workspaces.getActiveEngine().focusDirection(dir, screen_rect, global_gaps, &global_mins) orelse 0;
}

pub export fn talys_engine_swap_direction(direction: u8, screen_rect: Rect) bool {
    if (!is_initialized) return false;
    if (direction > 3) return false;
    const dir: Direction = @enumFromInt(direction);
    return global_workspaces.getActiveEngine().swapDirection(dir, screen_rect, global_gaps, &global_mins);
}

/// Swaps two tiled windows on whichever workspace holds both.
pub export fn talys_engine_swap_windows(a: WindowId, b: WindowId) bool {
    if (!is_initialized) return false;
    const ws = global_workspaces.findWorkspaceForWindow(a) orelse return false;
    if (global_workspaces.findWorkspaceForWindow(b) != ws) return false;
    const engine = global_workspaces.getEngine(ws) orelse return false;
    return engine.swapWindows(a, b);
}

pub export fn talys_engine_resize_focused(delta: f64) void {
    if (!is_initialized) return;
    global_workspaces.getActiveEngine().resizeFocused(delta);
}

pub export fn talys_engine_toggle_float(wid: WindowId) bool {
    if (!is_initialized) talys_engine_init();
    return global_workspaces.getActiveEngine().toggleFloat(wid);
}

pub export fn talys_engine_is_floating(wid: WindowId) bool {
    if (!is_initialized) return false;
    return global_workspaces.getActiveEngine().isFloating(wid);
}

pub export fn talys_engine_toggle_fullscreen() void {
    if (!is_initialized) return;
    global_workspaces.getActiveEngine().toggleFullscreen();
}

pub export fn talys_engine_is_fullscreen() bool {
    if (!is_initialized) return false;
    return global_workspaces.getActiveEngine().isFullscreen();
}

pub export fn talys_engine_cycle_layout() void {
    if (!is_initialized) return;
    global_workspaces.getActiveEngine().cycleLayout();
}

pub export fn talys_engine_get_layout_mode() u8 {
    if (!is_initialized) return 0;
    return @intFromEnum(global_workspaces.getActiveEngine().layout_mode);
}

pub export fn talys_engine_set_layout_mode(mode: u8) void {
    if (!is_initialized) return;
    if (mode <= 3) {
        global_workspaces.getActiveEngine().layout_mode = @enumFromInt(mode);
    }
}

pub export fn talys_engine_calculate_layout(
    screen_rect: Rect,
    max_count: usize,
    out_ids: [*]WindowId,
    out_rects: [*]Rect,
) c_int {
    if (!is_initialized) return 0;
    const count = global_workspaces.getActiveEngine().calculateLayout(
        screen_rect,
        global_gaps,
        &global_mins,
        max_count,
        out_ids,
        out_rects,
    );
    return @as(c_int, @intCast(count));
}

pub export fn talys_engine_cycle_column_width() void {
    if (!is_initialized) return;
    global_workspaces.getActiveEngine().cycleColumnWidth();
}

pub export fn talys_engine_consume_or_expel(direction: u8) bool {
    if (!is_initialized) return false;
    if (direction > 3) return false;
    return global_workspaces.getActiveEngine().consumeOrExpel(@enumFromInt(direction));
}

pub export fn talys_engine_get_active_workspace() u8 {
    if (!is_initialized) return 1;
    return global_workspaces.getActiveWorkspace();
}

pub export fn talys_engine_switch_workspace(
    target_ws: u8,
    out_hide_ids: [*]WindowId,
    max_hide: usize,
    out_show_ids: [*]WindowId,
    max_show: usize,
    out_counts: *SwitchCounts,
) bool {
    if (!is_initialized) talys_engine_init();
    return global_workspaces.switchWorkspace(target_ws, out_hide_ids, max_hide, out_show_ids, max_show, out_counts);
}

pub export fn talys_engine_move_to_workspace(wid: WindowId, target_ws: u8) bool {
    if (!is_initialized) return false;
    return global_workspaces.moveWindowToWorkspace(wid, target_ws);
}

/// Whether `wid` would get its minimum size as a tiled window on workspace `ws`.
pub export fn talys_engine_fits_on_workspace(wid: WindowId, ws: u8, screen_rect: Rect) bool {
    if (!is_initialized) return true;
    return global_workspaces.fitsOn(wid, ws, screen_rect, global_gaps, &global_mins);
}

/// First workspace after `after` (wrapping, skipping `after` and `skip`) where `wid` fits; 0 if none.
pub export fn talys_engine_find_room(wid: WindowId, after: u8, skip: u8, screen_rect: Rect) u8 {
    if (!is_initialized) return 0;
    return global_workspaces.findRoom(wid, after, skip, screen_rect, global_gaps, &global_mins);
}

pub export fn talys_engine_get_workspace_window_count(ws: u8) usize {
    if (!is_initialized) return 0;
    return global_workspaces.getWorkspaceWindowCount(ws);
}

test "tiling export wrappers" {
    talys_engine_init();
    talys_engine_set_gaps(8.0, 10.0);

    talys_engine_add_window(10);
    talys_engine_add_window(20);

    var ids: [10]WindowId = undefined;
    var rects: [10]Rect = undefined;
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const count = talys_engine_calculate_layout(screen, 10, &ids, &rects);
    try std.testing.expectEqual(@as(c_int, 2), count);

    const f = talys_engine_get_focus();
    try std.testing.expectEqual(@as(WindowId, 20), f);

    const focused_left = talys_engine_focus_direction(0, screen);
    try std.testing.expectEqual(@as(WindowId, 10), focused_left);

    var hide_ids: [10]WindowId = undefined;
    var show_ids: [10]WindowId = undefined;
    var counts: SwitchCounts = undefined;
    const switched = talys_engine_switch_workspace(2, &hide_ids, 10, &show_ids, 10, &counts);
    try std.testing.expect(switched);
    try std.testing.expectEqual(@as(u8, 2), talys_engine_get_active_workspace());
    try std.testing.expectEqual(@as(usize, 2), counts.hide_count);

    talys_engine_remove_window(10);
    const count_after = talys_engine_calculate_layout(screen, 10, &ids, &rects);
    try std.testing.expectEqual(@as(c_int, 0), count_after);
}
