const std = @import("std");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const GapConfig = geometry.GapConfig;

pub const WindowId = u32;
pub const NodeIndex = u16;
pub const null_node: NodeIndex = 0xFFFF;
pub const MAX_NODES: usize = 512;
pub const MAX_WINDOWS: usize = 256;

pub const Direction = enum(u8) {
    left = 0,
    down = 1,
    up = 2,
    right = 3,
};

pub const SplitDirection = enum(u8) {
    horizontal = 0,
    vertical = 1,
};

pub const LayoutMode = enum(u8) {
    dwindle = 0,
    master_stack = 1,
    monocle = 2,
};

pub const NodeData = union(enum) {
    empty,
    leaf: struct {
        window_id: WindowId,
    },
    branch: struct {
        split_dir: SplitDirection,
        ratio: f64,
        left: NodeIndex,
        right: NodeIndex,
    },
};

pub const Node = struct {
    data: NodeData = .empty,
    parent: NodeIndex = null_node,
};

pub const BspEngine = struct {
    nodes: [MAX_NODES]Node = [_]Node{.{}} ** MAX_NODES,
    free_list: [MAX_NODES]NodeIndex = undefined,
    free_count: usize = 0,

    root: NodeIndex = null_node,
    focused_window: ?WindowId = null,
    layout_mode: LayoutMode = .dwindle,
    fullscreen: bool = false,

    floating_windows: [MAX_WINDOWS]WindowId = undefined,
    floating_count: usize = 0,

    pub fn init() BspEngine {
        var engine = BspEngine{};
        engine.reset();
        return engine;
    }

    pub fn reset(self: *BspEngine) void {
        self.root = null_node;
        self.focused_window = null;
        self.layout_mode = .dwindle;
        self.fullscreen = false;
        self.floating_count = 0;

        self.free_count = MAX_NODES;
        for (0..MAX_NODES) |i| {
            self.nodes[i] = Node{
                .data = .empty,
                .parent = null_node,
            };
            self.free_list[i] = @as(NodeIndex, @intCast(MAX_NODES - 1 - i));
        }
    }

    fn allocNode(self: *BspEngine) ?NodeIndex {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const idx = self.free_list[self.free_count];
        self.nodes[idx] = Node{
            .data = .empty,
            .parent = null_node,
        };
        return idx;
    }

    fn freeNode(self: *BspEngine, idx: NodeIndex) void {
        if (idx == null_node or idx >= MAX_NODES) return;
        self.nodes[idx].data = .empty;
        self.nodes[idx].parent = null_node;
        self.free_list[self.free_count] = idx;
        self.free_count += 1;
    }

    pub fn isFloating(self: *const BspEngine, wid: WindowId) bool {
        for (0..self.floating_count) |i| {
            if (self.floating_windows[i] == wid) return true;
        }
        return false;
    }

    fn removeFloating(self: *BspEngine, wid: WindowId) bool {
        for (0..self.floating_count) |i| {
            if (self.floating_windows[i] == wid) {
                for (i..self.floating_count - 1) |j| {
                    self.floating_windows[j] = self.floating_windows[j + 1];
                }
                self.floating_count -= 1;
                return true;
            }
        }
        return false;
    }

    fn addFloating(self: *BspEngine, wid: WindowId) void {
        if (self.isFloating(wid)) return;
        if (self.floating_count < MAX_WINDOWS) {
            self.floating_windows[self.floating_count] = wid;
            self.floating_count += 1;
        }
    }

    pub fn findLeafByWindow(self: *const BspEngine, wid: WindowId) NodeIndex {
        if (self.root == null_node) return null_node;
        return self.findLeafInSubtree(self.root, wid);
    }

    fn findLeafInSubtree(self: *const BspEngine, node_idx: NodeIndex, wid: WindowId) NodeIndex {
        if (node_idx == null_node) return null_node;
        const node = &self.nodes[node_idx];
        switch (node.data) {
            .leaf => |leaf| {
                if (leaf.window_id == wid) return node_idx;
                return null_node;
            },
            .branch => |branch| {
                const left_res = self.findLeafInSubtree(branch.left, wid);
                if (left_res != null_node) return left_res;
                return self.findLeafInSubtree(branch.right, wid);
            },
            .empty => return null_node,
        }
    }

    pub fn hasWindow(self: *const BspEngine, wid: WindowId) bool {
        if (self.isFloating(wid)) return true;
        return self.findLeafByWindow(wid) != null_node;
    }

    pub fn getFirstLeafWindow(self: *const BspEngine, node_idx: NodeIndex) ?WindowId {
        if (node_idx == null_node) return null;
        const node = &self.nodes[node_idx];
        switch (node.data) {
            .leaf => |leaf| return leaf.window_id,
            .branch => |branch| {
                if (self.getFirstLeafWindow(branch.left)) |w| return w;
                return self.getFirstLeafWindow(branch.right);
            },
            .empty => return null,
        }
    }

    pub fn addWindow(self: *BspEngine, wid: WindowId) void {
        if (self.hasWindow(wid)) return;

        if (self.root == null_node) {
            const leaf_idx = self.allocNode() orelse return;
            self.nodes[leaf_idx].data = .{ .leaf = .{ .window_id = wid } };
            self.nodes[leaf_idx].parent = null_node;
            self.root = leaf_idx;
            self.focused_window = wid;
            return;
        }

        var target_leaf: NodeIndex = null_node;
        if (self.focused_window) |fwid| {
            target_leaf = self.findLeafByWindow(fwid);
        }
        if (target_leaf == null_node) {
            target_leaf = self.findFirstLeaf(self.root);
        }
        if (target_leaf == null_node) return;

        const branch_idx = self.allocNode() orelse return;
        const new_leaf_idx = self.allocNode() orelse {
            self.freeNode(branch_idx);
            return;
        };

        const parent_idx = self.nodes[target_leaf].parent;
        var split_dir: SplitDirection = .horizontal;
        if (parent_idx != null_node) {
            if (self.nodes[parent_idx].data == .branch) {
                const p_dir = self.nodes[parent_idx].data.branch.split_dir;
                split_dir = if (p_dir == .horizontal) .vertical else .horizontal;
            }
        }

        self.nodes[new_leaf_idx].data = .{ .leaf = .{ .window_id = wid } };
        self.nodes[new_leaf_idx].parent = branch_idx;

        self.nodes[branch_idx].data = .{
            .branch = .{
                .split_dir = split_dir,
                .ratio = 0.5,
                .left = target_leaf,
                .right = new_leaf_idx,
            },
        };
        self.nodes[branch_idx].parent = parent_idx;

        self.nodes[target_leaf].parent = branch_idx;

        if (parent_idx != null_node) {
            if (self.nodes[parent_idx].data.branch.left == target_leaf) {
                self.nodes[parent_idx].data.branch.left = branch_idx;
            } else {
                self.nodes[parent_idx].data.branch.right = branch_idx;
            }
        } else {
            self.root = branch_idx;
        }

        self.focused_window = wid;
    }

    fn findFirstLeaf(self: *const BspEngine, node_idx: NodeIndex) NodeIndex {
        if (node_idx == null_node) return null_node;
        const node = &self.nodes[node_idx];
        switch (node.data) {
            .leaf => return node_idx,
            .branch => |branch| {
                const l = self.findFirstLeaf(branch.left);
                if (l != null_node) return l;
                return self.findFirstLeaf(branch.right);
            },
            .empty => return null_node,
        }
    }

    pub fn removeWindow(self: *BspEngine, wid: WindowId) void {
        if (self.removeFloating(wid)) {
            if (self.focused_window == wid) {
                self.focused_window = self.getFirstLeafWindow(self.root);
            }
            return;
        }

        const leaf_idx = self.findLeafByWindow(wid);
        if (leaf_idx == null_node) return;

        if (leaf_idx == self.root) {
            self.freeNode(leaf_idx);
            self.root = null_node;
            self.focused_window = null;
            return;
        }

        const parent_idx = self.nodes[leaf_idx].parent;
        const p_node = &self.nodes[parent_idx];
        const sibling_idx = if (p_node.data.branch.left == leaf_idx)
            p_node.data.branch.right
        else
            p_node.data.branch.left;

        const grandparent_idx = p_node.parent;
        self.nodes[sibling_idx].parent = grandparent_idx;

        if (grandparent_idx != null_node) {
            if (self.nodes[grandparent_idx].data.branch.left == parent_idx) {
                self.nodes[grandparent_idx].data.branch.left = sibling_idx;
            } else {
                self.nodes[grandparent_idx].data.branch.right = sibling_idx;
            }
        } else {
            self.root = sibling_idx;
        }

        self.freeNode(leaf_idx);
        self.freeNode(parent_idx);

        if (self.focused_window == wid) {
            self.focused_window = self.getFirstLeafWindow(sibling_idx);
        }
    }

    pub fn setFocus(self: *BspEngine, wid: WindowId) void {
        if (self.hasWindow(wid)) {
            self.focused_window = wid;
        }
    }

    pub fn getFocus(self: *const BspEngine) ?WindowId {
        return self.focused_window;
    }

    pub fn toggleFloat(self: *BspEngine, wid: WindowId) bool {
        if (self.isFloating(wid)) {
            _ = self.removeFloating(wid);
            self.addWindow(wid);
            return false;
        } else if (self.findLeafByWindow(wid) != null_node) {
            self.removeWindow(wid);
            self.addFloating(wid);
            self.focused_window = wid;
            return true;
        } else {
            self.addFloating(wid);
            self.focused_window = wid;
            return true;
        }
    }

    pub fn toggleFullscreen(self: *BspEngine) void {
        self.fullscreen = !self.fullscreen;
    }

    pub fn isFullscreen(self: *const BspEngine) bool {
        return self.fullscreen;
    }

    pub fn cycleLayout(self: *BspEngine) void {
        self.layout_mode = switch (self.layout_mode) {
            .dwindle => .master_stack,
            .master_stack => .monocle,
            .monocle => .dwindle,
        };
    }

    pub fn resizeFocused(self: *BspEngine, delta: f64) void {
        const wid = self.focused_window orelse return;
        const leaf_idx = self.findLeafByWindow(wid);
        if (leaf_idx == null_node) return;

        const parent_idx = self.nodes[leaf_idx].parent;
        if (parent_idx == null_node) return;

        const branch = &self.nodes[parent_idx].data.branch;
        if (branch.left == leaf_idx) {
            branch.ratio = std.math.clamp(branch.ratio + delta, 0.15, 0.85);
        } else {
            branch.ratio = std.math.clamp(branch.ratio - delta, 0.15, 0.85);
        }
    }

    pub fn calculateLayout(
        self: *const BspEngine,
        screen_rect: Rect,
        gaps: GapConfig,
        max_count: usize,
        out_ids: [*]WindowId,
        out_rects: [*]Rect,
    ) usize {
        if (max_count == 0) return 0;

        if (self.fullscreen or self.layout_mode == .monocle) {
            const wid = self.focused_window orelse (if (self.root != null_node) self.getFirstLeafWindow(self.root) else null) orelse return 0;
            out_ids[0] = wid;
            out_rects[0] = screen_rect.insetUniform(gaps.outer);
            return 1;
        }

        switch (self.layout_mode) {
            .dwindle => {
                if (self.root == null_node) return 0;
                const usable_rect = screen_rect.insetUniform(gaps.outer);
                var count: usize = 0;
                self.renderNode(self.root, usable_rect, gaps.inner, max_count, out_ids, out_rects, &count);
                return count;
            },
            .master_stack => {
                var windows: [MAX_WINDOWS]WindowId = undefined;
                var total: usize = 0;
                self.collectLeaves(self.root, &windows, &total);
                if (total == 0) return 0;

                const usable_rect = screen_rect.insetUniform(gaps.outer);
                if (total == 1) {
                    out_ids[0] = windows[0];
                    out_rects[0] = usable_rect;
                    return 1;
                }

                const limit = @min(total, max_count);
                const inner = gaps.inner;
                const master_w = @max(0.0, (usable_rect.width - inner) * 0.5);
                const stack_w = @max(0.0, usable_rect.width - inner - master_w);

                out_ids[0] = windows[0];
                out_rects[0] = Rect{
                    .x = usable_rect.x,
                    .y = usable_rect.y,
                    .width = master_w,
                    .height = usable_rect.height,
                };

                const stack_count = limit - 1;
                const stack_inner_total = inner * @as(f64, @floatFromInt(stack_count - 1));
                const total_stack_h = @max(0.0, usable_rect.height - stack_inner_total);
                const stack_h = total_stack_h / @as(f64, @floatFromInt(stack_count));

                var curr_y = usable_rect.y;
                for (1..limit) |i| {
                    out_ids[i] = windows[i];
                    out_rects[i] = Rect{
                        .x = usable_rect.x + master_w + inner,
                        .y = curr_y,
                        .width = stack_w,
                        .height = stack_h,
                    };
                    curr_y += stack_h + inner;
                }
                return limit;
            },
            .monocle => unreachable,
        }
    }

    pub fn collectLeaves(self: *const BspEngine, node_idx: NodeIndex, list: *[MAX_WINDOWS]WindowId, count: *usize) void {
        if (node_idx == null_node or count.* >= MAX_WINDOWS) return;
        const node = &self.nodes[node_idx];
        switch (node.data) {
            .leaf => |leaf| {
                list[count.*] = leaf.window_id;
                count.* += 1;
            },
            .branch => |branch| {
                self.collectLeaves(branch.left, list, count);
                self.collectLeaves(branch.right, list, count);
            },
            .empty => {},
        }
    }

    pub fn collectAllWindows(self: *const BspEngine, list: *[MAX_WINDOWS]WindowId, count: *usize) void {
        self.collectLeaves(self.root, list, count);
        for (0..self.floating_count) |i| {
            if (count.* < MAX_WINDOWS) {
                list[count.*] = self.floating_windows[i];
                count.* += 1;
            }
        }
    }

    fn renderNode(
        self: *const BspEngine,
        node_idx: NodeIndex,
        rect: Rect,
        inner_gap: f64,
        max_count: usize,
        out_ids: [*]WindowId,
        out_rects: [*]Rect,
        count: *usize,
    ) void {
        if (node_idx == null_node or count.* >= max_count) return;

        const node = &self.nodes[node_idx];
        switch (node.data) {
            .leaf => |leaf| {
                out_ids[count.*] = leaf.window_id;
                out_rects[count.*] = rect;
                count.* += 1;
            },
            .branch => |branch| {
                switch (branch.split_dir) {
                    .horizontal => {
                        const total_w = @max(0.0, rect.width - inner_gap);
                        const left_w = @round(total_w * branch.ratio);
                        const right_w = @max(0.0, total_w - left_w);

                        const left_rect = Rect{
                            .x = rect.x,
                            .y = rect.y,
                            .width = left_w,
                            .height = rect.height,
                        };
                        const right_rect = Rect{
                            .x = rect.x + left_w + inner_gap,
                            .y = rect.y,
                            .width = right_w,
                            .height = rect.height,
                        };

                        self.renderNode(branch.left, left_rect, inner_gap, max_count, out_ids, out_rects, count);
                        self.renderNode(branch.right, right_rect, inner_gap, max_count, out_ids, out_rects, count);
                    },
                    .vertical => {
                        const total_h = @max(0.0, rect.height - inner_gap);
                        const top_h = @round(total_h * branch.ratio);
                        const bottom_h = @max(0.0, total_h - top_h);

                        const top_rect = Rect{
                            .x = rect.x,
                            .y = rect.y,
                            .width = rect.width,
                            .height = top_h,
                        };
                        const bottom_rect = Rect{
                            .x = rect.x,
                            .y = rect.y + top_h + inner_gap,
                            .width = rect.width,
                            .height = bottom_h,
                        };

                        self.renderNode(branch.left, top_rect, inner_gap, max_count, out_ids, out_rects, count);
                        self.renderNode(branch.right, bottom_rect, inner_gap, max_count, out_ids, out_rects, count);
                    },
                }
            },
            .empty => {},
        }
    }

    pub fn findNeighbor(
        self: *const BspEngine,
        dir: Direction,
        screen_rect: Rect,
        gaps: GapConfig,
    ) ?WindowId {
        const focused = self.focused_window orelse return null;

        var ids: [MAX_WINDOWS]WindowId = undefined;
        var rects: [MAX_WINDOWS]Rect = undefined;
        const count = self.calculateLayout(screen_rect, gaps, MAX_WINDOWS, &ids, &rects);
        if (count <= 1) return null;

        var focused_rect: ?Rect = null;
        for (0..count) |i| {
            if (ids[i] == focused) {
                focused_rect = rects[i];
                break;
            }
        }
        const F = focused_rect orelse return null;

        var best_id: ?WindowId = null;
        var best_score: f64 = std.math.floatMax(f64);

        for (0..count) |i| {
            const wid = ids[i];
            if (wid == focused) continue;
            const C = rects[i];

            var valid = false;
            var score: f64 = 0;

            switch (dir) {
                .left => {
                    if (C.centerX() < F.centerX() - 1.0) {
                        valid = true;
                        const dx = F.centerX() - C.centerX();
                        const dy = @abs(F.centerY() - C.centerY());
                        const overlap = @max(0.0, @min(F.y + F.height, C.y + C.height) - @max(F.y, C.y));
                        score = dx + dy * 2.0 - overlap * 0.8;
                    }
                },
                .right => {
                    if (C.centerX() > F.centerX() + 1.0) {
                        valid = true;
                        const dx = C.centerX() - F.centerX();
                        const dy = @abs(F.centerY() - C.centerY());
                        const overlap = @max(0.0, @min(F.y + F.height, C.y + C.height) - @max(F.y, C.y));
                        score = dx + dy * 2.0 - overlap * 0.8;
                    }
                },
                .up => {
                    if (C.centerY() < F.centerY() - 1.0) {
                        valid = true;
                        const dy = F.centerY() - C.centerY();
                        const dx = @abs(F.centerX() - C.centerX());
                        const overlap = @max(0.0, @min(F.x + F.width, C.x + C.width) - @max(F.x, C.x));
                        score = dy + dx * 2.0 - overlap * 0.8;
                    }
                },
                .down => {
                    if (C.centerY() > F.centerY() + 1.0) {
                        valid = true;
                        const dy = C.centerY() - F.centerY();
                        const dx = @abs(F.centerX() - C.centerX());
                        const overlap = @max(0.0, @min(F.x + F.width, C.x + C.width) - @max(F.x, C.x));
                        score = dy + dx * 2.0 - overlap * 0.8;
                    }
                },
            }

            if (valid and score < best_score) {
                best_score = score;
                best_id = wid;
            }
        }

        return best_id;
    }

    pub fn focusDirection(
        self: *BspEngine,
        dir: Direction,
        screen_rect: Rect,
        gaps: GapConfig,
    ) ?WindowId {
        if (self.findNeighbor(dir, screen_rect, gaps)) |target_wid| {
            self.focused_window = target_wid;
            return target_wid;
        }
        return null;
    }

    pub fn swapDirection(
        self: *BspEngine,
        dir: Direction,
        screen_rect: Rect,
        gaps: GapConfig,
    ) bool {
        const focused = self.focused_window orelse return false;
        const target_wid = self.findNeighbor(dir, screen_rect, gaps) orelse return false;

        const leaf1 = self.findLeafByWindow(focused);
        const leaf2 = self.findLeafByWindow(target_wid);
        if (leaf1 == null_node or leaf2 == null_node) return false;

        self.nodes[leaf1].data.leaf.window_id = target_wid;
        self.nodes[leaf2].data.leaf.window_id = focused;

        self.focused_window = focused;
        return true;
    }
};

test "BspEngine basic add, remove, focus" {
    var engine = BspEngine.init();
    engine.addWindow(100);
    try std.testing.expectEqual(@as(?WindowId, 100), engine.getFocus());
    try std.testing.expect(engine.hasWindow(100));

    engine.addWindow(200);
    try std.testing.expectEqual(@as(?WindowId, 200), engine.getFocus());
    try std.testing.expect(engine.hasWindow(200));

    engine.addWindow(300);
    try std.testing.expectEqual(@as(?WindowId, 300), engine.getFocus());

    var ids: [10]WindowId = undefined;
    var rects: [10]Rect = undefined;
    const count = engine.calculateLayout(
        .{ .x = 0, .y = 0, .width = 1000, .height = 500 },
        .{ .inner = 10, .outer = 10 },
        10,
        &ids,
        &rects,
    );
    try std.testing.expectEqual(@as(usize, 3), count);

    engine.removeWindow(200);
    try std.testing.expect(!engine.hasWindow(200));

    const count2 = engine.calculateLayout(
        .{ .x = 0, .y = 0, .width = 1000, .height = 500 },
        .{ .inner = 10, .outer = 10 },
        10,
        &ids,
        &rects,
    );
    try std.testing.expectEqual(@as(usize, 2), count2);
}

test "BspEngine focus and swap directional" {
    var engine = BspEngine.init();
    engine.addWindow(1);
    engine.addWindow(2);

    const screen = Rect{ .x = 0, .y = 0, .width = 1000, .height = 500 };
    const gaps = GapConfig{ .inner = 10, .outer = 10 };

    const left_wid = engine.focusDirection(.left, screen, gaps);
    try std.testing.expectEqual(@as(?WindowId, 1), left_wid);
    try std.testing.expectEqual(@as(?WindowId, 1), engine.getFocus());

    const right_wid = engine.focusDirection(.right, screen, gaps);
    try std.testing.expectEqual(@as(?WindowId, 2), right_wid);

    const swapped = engine.swapDirection(.left, screen, gaps);
    try std.testing.expect(swapped);
}

test "BspEngine floating and fullscreen" {
    var engine = BspEngine.init();
    engine.addWindow(1);
    engine.addWindow(2);

    try std.testing.expect(!engine.isFloating(1));
    const became_floating = engine.toggleFloat(1);
    try std.testing.expect(became_floating);
    try std.testing.expect(engine.isFloating(1));

    var ids: [10]WindowId = undefined;
    var rects: [10]Rect = undefined;
    const count = engine.calculateLayout(
        .{ .x = 0, .y = 0, .width = 1000, .height = 500 },
        .{ .inner = 10, .outer = 10 },
        10,
        &ids,
        &rects,
    );
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(WindowId, 2), ids[0]);

    const now_floating = engine.toggleFloat(1);
    try std.testing.expect(!now_floating);
    try std.testing.expect(!engine.isFloating(1));

    try std.testing.expect(!engine.isFullscreen());
    engine.toggleFullscreen();
    try std.testing.expect(engine.isFullscreen());
    const count_fs = engine.calculateLayout(
        .{ .x = 0, .y = 0, .width = 1000, .height = 500 },
        .{ .inner = 10, .outer = 10 },
        10,
        &ids,
        &rects,
    );
    try std.testing.expectEqual(@as(usize, 1), count_fs);
}
