const std = @import("std");
const bsp = @import("bsp.zig");
const geometry = @import("geometry.zig");
const constraints = @import("constraints.zig");
const WindowHints = constraints.WindowHints;

pub const WindowId = bsp.WindowId;
pub const Rect = geometry.Rect;
pub const GapConfig = geometry.GapConfig;
pub const WORKSPACE_COUNT: usize = 9;

pub const SwitchCounts = extern struct {
    hide_count: usize,
    show_count: usize,
};

pub const WorkspaceManager = struct {
    workspaces: [WORKSPACE_COUNT]bsp.BspEngine = undefined,
    active_workspace: u8 = 1,
    /// Layout every workspace starts in, and goes back to on a reset.
    default_layout: bsp.LayoutMode = .smart,

    pub fn init() WorkspaceManager {
        var wm = WorkspaceManager{
            .active_workspace = 1,
        };
        for (0..WORKSPACE_COUNT) |i| {
            wm.workspaces[i] = bsp.BspEngine.init();
            wm.workspaces[i].setLayoutMode(wm.default_layout);
        }
        return wm;
    }

    pub fn reset(self: *WorkspaceManager) void {
        self.active_workspace = 1;
        for (0..WORKSPACE_COUNT) |i| {
            self.workspaces[i].reset();
            self.workspaces[i].setLayoutMode(self.default_layout);
        }
    }

    /// Puts every workspace in `mode` and makes it the one they reset to.
    pub fn setDefaultLayout(self: *WorkspaceManager, mode: bsp.LayoutMode) void {
        self.default_layout = mode;
        for (0..WORKSPACE_COUNT) |i| self.workspaces[i].setLayoutMode(mode);
    }

    pub fn getActiveWorkspace(self: *const WorkspaceManager) u8 {
        return self.active_workspace;
    }

    pub fn getActiveEngine(self: *WorkspaceManager) *bsp.BspEngine {
        const idx = @as(usize, self.active_workspace - 1);
        return &self.workspaces[idx];
    }

    pub fn getActiveEngineConst(self: *const WorkspaceManager) *const bsp.BspEngine {
        const idx = @as(usize, self.active_workspace - 1);
        return &self.workspaces[idx];
    }

    pub fn getEngine(self: *WorkspaceManager, ws: u8) ?*bsp.BspEngine {
        if (ws < 1 or ws > WORKSPACE_COUNT) return null;
        return &self.workspaces[@as(usize, ws - 1)];
    }

    pub fn findWorkspaceForWindow(self: *const WorkspaceManager, wid: WindowId) ?u8 {
        for (0..WORKSPACE_COUNT) |i| {
            if (self.workspaces[i].hasWindow(wid)) {
                return @as(u8, @intCast(i + 1));
            }
        }
        return null;
    }

    pub fn addWindow(self: *WorkspaceManager, wid: WindowId) void {
        self.getActiveEngine().addWindow(wid);
    }

    pub fn addWindowToWorkspace(self: *WorkspaceManager, wid: WindowId, ws: u8) void {
        if (self.getEngine(ws)) |engine| {
            engine.addWindow(wid);
        }
    }

    pub fn removeWindow(self: *WorkspaceManager, wid: WindowId) void {
        for (0..WORKSPACE_COUNT) |i| {
            if (self.workspaces[i].hasWindow(wid)) {
                self.workspaces[i].removeWindow(wid);
                return;
            }
        }
    }

    pub fn hasWindow(self: *const WorkspaceManager, wid: WindowId) bool {
        return self.findWorkspaceForWindow(wid) != null;
    }

    pub fn switchWorkspace(
        self: *WorkspaceManager,
        target_ws: u8,
        out_hide_ids: [*]WindowId,
        max_hide: usize,
        out_show_ids: [*]WindowId,
        max_show: usize,
        out_counts: *SwitchCounts,
    ) bool {
        if (target_ws < 1 or target_ws > WORKSPACE_COUNT) return false;
        if (target_ws == self.active_workspace) {
            out_counts.hide_count = 0;
            out_counts.show_count = 0;
            return true;
        }

        var hide_list: [bsp.MAX_WINDOWS]WindowId = undefined;
        var hide_total: usize = 0;
        self.getActiveEngineConst().collectAllWindows(&hide_list, &hide_total);

        const hide_limit = @min(hide_total, max_hide);
        for (0..hide_limit) |i| {
            out_hide_ids[i] = hide_list[i];
        }
        out_counts.hide_count = hide_limit;

        self.active_workspace = target_ws;

        var show_list: [bsp.MAX_WINDOWS]WindowId = undefined;
        var show_total: usize = 0;
        self.getActiveEngineConst().collectAllWindows(&show_list, &show_total);

        const show_limit = @min(show_total, max_show);
        for (0..show_limit) |i| {
            out_show_ids[i] = show_list[i];
        }
        out_counts.show_count = show_limit;

        return true;
    }

    pub fn moveWindowToWorkspace(self: *WorkspaceManager, wid: WindowId, target_ws: u8) bool {
        if (target_ws < 1 or target_ws > WORKSPACE_COUNT) return false;
        const current_ws = self.findWorkspaceForWindow(wid) orelse return false;
        if (current_ws == target_ws) return false;

        const src_engine = &self.workspaces[@as(usize, current_ws - 1)];
        const dst_engine = &self.workspaces[@as(usize, target_ws - 1)];

        const is_floating = src_engine.isFloating(wid);
        src_engine.removeWindow(wid);

        if (is_floating) {
            _ = dst_engine.toggleFloat(wid);
        } else {
            dst_engine.addWindow(wid);
        }

        return true;
    }

    /// Whether `wid` would get at least its minimum size as a tiled window on workspace `ws`
    /// (tried on a copy, so nothing changes).
    pub fn fitsOn(self: *const WorkspaceManager, wid: WindowId, ws: u8, screen_rect: Rect, gaps: GapConfig, mins: *const WindowHints) bool {
        if (ws < 1 or ws > WORKSPACE_COUNT) return false;
        var trial = self.workspaces[@as(usize, ws - 1)];
        if (!trial.hasWindow(wid)) trial.addWindow(wid);
        return trial.allFit(screen_rect, gaps, mins);
    }

    /// First workspace after `after` (wrapping around, never `after` or `skip`) where `wid` fits; 0 if none.
    pub fn findRoom(self: *const WorkspaceManager, wid: WindowId, after: u8, skip: u8, screen_rect: Rect, gaps: GapConfig, mins: *const WindowHints) u8 {
        const start: usize = if (after >= 1 and after <= WORKSPACE_COUNT) after - 1 else 0;
        for (1..WORKSPACE_COUNT) |step| {
            const ws: u8 = @intCast((start + step) % WORKSPACE_COUNT + 1);
            if (ws == skip) continue;
            if (self.fitsOn(wid, ws, screen_rect, gaps, mins)) return ws;
        }
        return 0;
    }

    pub fn getWorkspaceWindowCount(self: *const WorkspaceManager, ws: u8) usize {
        if (ws < 1 or ws > WORKSPACE_COUNT) return 0;
        const engine = &self.workspaces[@as(usize, ws - 1)];
        var list: [bsp.MAX_WINDOWS]WindowId = undefined;
        var count: usize = 0;
        engine.collectAllWindows(&list, &count);
        return count;
    }
};

test "WorkspaceManager basic operations" {
    var wm = WorkspaceManager.init();
    try std.testing.expectEqual(@as(u8, 1), wm.getActiveWorkspace());

    wm.addWindow(101);
    wm.addWindow(102);
    try std.testing.expect(wm.hasWindow(101));
    try std.testing.expectEqual(@as(?u8, 1), wm.findWorkspaceForWindow(101));
    try std.testing.expectEqual(@as(usize, 2), wm.getWorkspaceWindowCount(1));

    var hide_ids: [16]WindowId = undefined;
    var show_ids: [16]WindowId = undefined;
    var counts: SwitchCounts = undefined;

    const switched = wm.switchWorkspace(2, &hide_ids, 16, &show_ids, 16, &counts);
    try std.testing.expect(switched);
    try std.testing.expectEqual(@as(u8, 2), wm.getActiveWorkspace());
    try std.testing.expectEqual(@as(usize, 2), counts.hide_count);
    try std.testing.expectEqual(@as(usize, 0), counts.show_count);

    wm.addWindow(201);
    try std.testing.expectEqual(@as(usize, 1), wm.getWorkspaceWindowCount(2));

    const moved = wm.moveWindowToWorkspace(101, 2);
    try std.testing.expect(moved);
    try std.testing.expectEqual(@as(?u8, 2), wm.findWorkspaceForWindow(101));
    try std.testing.expectEqual(@as(usize, 1), wm.getWorkspaceWindowCount(1));
    try std.testing.expectEqual(@as(usize, 2), wm.getWorkspaceWindowCount(2));
}

test "WorkspaceManager finds a workspace with room" {
    var wm = WorkspaceManager.init();
    const screen = Rect{ .x = 0, .y = 0, .width = 1000, .height = 600 };
    const gaps = GapConfig{ .inner = 0, .outer = 0 };
    var mins = WindowHints{};
    mins.set(1, .{ .width = 700 });
    mins.set(2, .{ .width = 700 });
    mins.set(3, .{ .width = 700 });

    wm.addWindow(1);
    wm.addWindowToWorkspace(3, 2);
    // Too wide to sit side by side, but they fit stacked.
    try std.testing.expect(wm.fitsOn(2, 1, screen, gaps, &mins));
    mins.set(1, .{ .width = 700, .height = 400 });
    mins.set(2, .{ .width = 700, .height = 400 });
    mins.set(3, .{ .width = 700, .height = 400 });
    try std.testing.expect(!wm.fitsOn(2, 1, screen, gaps, &mins));
    // Workspace 2 holds 3 and is full too; 3 is the first with room. Workspace 1 is skipped.
    try std.testing.expectEqual(@as(u8, 3), wm.findRoom(2, 1, 1, screen, gaps, &mins));
    // Bigger than the screen: nowhere fits.
    mins.set(2, .{ .width = 1200 });
    try std.testing.expectEqual(@as(u8, 0), wm.findRoom(2, 1, 1, screen, gaps, &mins));
}
