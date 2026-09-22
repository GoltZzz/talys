const std = @import("std");
const bsp = @import("bsp.zig");
const geometry = @import("geometry.zig");

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

    pub fn init() WorkspaceManager {
        var wm = WorkspaceManager{
            .active_workspace = 1,
        };
        for (0..WORKSPACE_COUNT) |i| {
            wm.workspaces[i] = bsp.BspEngine.init();
        }
        return wm;
    }

    pub fn reset(self: *WorkspaceManager) void {
        self.active_workspace = 1;
        for (0..WORKSPACE_COUNT) |i| {
            self.workspaces[i].reset();
        }
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
