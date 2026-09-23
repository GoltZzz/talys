const std = @import("std");
const geometry = @import("geometry.zig");
const constraints = @import("constraints.zig");
const scroll = @import("scroll.zig");
const Rect = geometry.Rect;
const GapConfig = geometry.GapConfig;
const MinSizes = constraints.MinSizes;

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

pub const LayoutMode = enum(u8) {
    dwindle = 0,
    master_stack = 1,
    monocle = 2,
    scrolling = 3,
};

pub const NodeData = union(enum) {
    empty,
    leaf: struct {
        window_id: WindowId,
    },
    /// Split direction isn't stored: each branch splits along the longer side of the rect it gets,
    /// so tiles stay close to square however the tree was built.
    branch: struct {
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

    /// Column arrangement for the scrolling layout, kept in sync with the tree so either layout can be
    /// switched to without losing the other's arrangement.
    strip: scroll.ScrollStrip = .{},

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
        self.strip.reset();

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

        // New columns open right after the focused one.
        const anchor: ?usize = if (self.focused_window) |f| (if (self.strip.find(f)) |p| p.col else null) else null;
        self.strip.insertColumn(if (anchor) |a| a + 1 else self.strip.count, wid);

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

        self.nodes[new_leaf_idx].data = .{ .leaf = .{ .window_id = wid } };
        self.nodes[new_leaf_idx].parent = branch_idx;

        self.nodes[branch_idx].data = .{
            .branch = .{
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

        const strip_successor = if (self.layout_mode == .scrolling and self.focused_window == wid) self.strip.successor(wid) else null;
        self.strip.remove(wid);
        defer if (strip_successor) |next| {
            if (self.focused_window != null and self.hasWindow(next)) self.focused_window = next;
        };

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
            self.strip.markActive(wid);
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
            .master_stack => .scrolling,
            .scrolling => .monocle,
            .monocle => .dwindle,
        };
    }

    pub fn resizeFocused(self: *BspEngine, delta: f64) void {
        const wid = self.focused_window orelse return;
        if (self.layout_mode == .scrolling) {
            self.strip.resize(wid, delta);
            return;
        }
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
        self: *BspEngine,
        screen_rect: Rect,
        gaps: GapConfig,
        mins: *const MinSizes,
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
                self.renderNode(self.root, usable_rect, gaps.inner, mins, max_count, out_ids, out_rects, &count);
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
                const stack_count = limit - 1;

                // Master gets half, unless either side needs more to fit its windows' minimum widths.
                var stack_min_w: f64 = 0;
                var stack_min_hs: [MAX_WINDOWS]f64 = undefined;
                for (1..limit) |i| {
                    const m = mins.get(windows[i]);
                    stack_min_w = @max(stack_min_w, m.width);
                    stack_min_hs[i - 1] = m.height;
                }
                var widths: [2]f64 = undefined;
                _ = constraints.distribute(usable_rect.width, inner, &.{ mins.get(windows[0]).width, stack_min_w }, &widths);
                const master_w = widths[0];
                const stack_w = widths[1];

                out_ids[0] = windows[0];
                out_rects[0] = Rect{
                    .x = usable_rect.x,
                    .y = usable_rect.y,
                    .width = master_w,
                    .height = usable_rect.height,
                };

                var stack_hs: [MAX_WINDOWS]f64 = undefined;
                _ = constraints.distribute(usable_rect.height, inner, stack_min_hs[0..stack_count], stack_hs[0..stack_count]);

                var curr_y = usable_rect.y;
                for (1..limit) |i| {
                    out_ids[i] = windows[i];
                    out_rects[i] = Rect{
                        .x = usable_rect.x + master_w + inner,
                        .y = curr_y,
                        .width = stack_w,
                        .height = stack_hs[i - 1],
                    };
                    curr_y += stack_hs[i - 1] + inner;
                }
                return limit;
            },
            .scrolling => return self.strip.layout(screen_rect, gaps, mins, self.focused_window, max_count, out_ids, out_rects),
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

    /// Cuts `rect` in two along its width (`side_by_side`) or height, the first part `first` long.
    fn splitRect(rect: Rect, side_by_side: bool, gap: f64, first: f64) [2]Rect {
        if (side_by_side) {
            const total = @max(0.0, rect.width - gap);
            return .{
                .{ .x = rect.x, .y = rect.y, .width = first, .height = rect.height },
                .{ .x = rect.x + first + gap, .y = rect.y, .width = @max(0.0, total - first), .height = rect.height },
            };
        }
        const total = @max(0.0, rect.height - gap);
        return .{
            .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = first },
            .{ .x = rect.x, .y = rect.y + first + gap, .width = rect.width, .height = @max(0.0, total - first) },
        };
    }

    /// Smallest width (`along_width`) or height the subtree can be squeezed into, laid out as it would be in `rect`.
    fn minExtent(self: *const BspEngine, node_idx: NodeIndex, rect: Rect, gap: f64, mins: *const MinSizes, along_width: bool) f64 {
        if (node_idx == null_node) return 0;
        switch (self.nodes[node_idx].data) {
            .leaf => |leaf| {
                const m = mins.get(leaf.window_id);
                return if (along_width) m.width else m.height;
            },
            .branch => |branch| {
                const side_by_side = rect.width >= rect.height;
                const total = if (side_by_side) rect.width - gap else rect.height - gap;
                const parts = splitRect(rect, side_by_side, gap, @round(@max(0.0, total) * branch.ratio));
                const a = self.minExtent(branch.left, parts[0], gap, mins, along_width);
                const b = self.minExtent(branch.right, parts[1], gap, mins, along_width);
                return if (side_by_side == along_width) a + gap + b else @max(a, b);
            },
            .empty => return 0,
        }
    }

    /// Splits a branch's rect so both halves fit their windows' minimum sizes, moving the divider and, if that
    /// isn't enough, flipping the split direction. Returns null when neither direction fits.
    fn fitSplit(self: *const BspEngine, branch_left: NodeIndex, branch_right: NodeIndex, ratio: f64, rect: Rect, gap: f64, mins: *const MinSizes, side_by_side: bool) ?[2]Rect {
        const total = @max(0.0, if (side_by_side) rect.width - gap else rect.height - gap);
        const cross = if (side_by_side) rect.height else rect.width;
        const nominal = splitRect(rect, side_by_side, gap, @round(total * ratio));

        const need_a = self.minExtent(branch_left, nominal[0], gap, mins, side_by_side);
        const need_b = self.minExtent(branch_right, nominal[1], gap, mins, side_by_side);
        const cross_a = self.minExtent(branch_left, nominal[0], gap, mins, !side_by_side);
        const cross_b = self.minExtent(branch_right, nominal[1], gap, mins, !side_by_side);
        if (need_a + need_b > total + 0.5 or @max(cross_a, cross_b) > cross + 0.5) return null;

        const first = std.math.clamp(@round(total * ratio), need_a, total - need_b);
        return splitRect(rect, side_by_side, gap, first);
    }

    fn renderNode(
        self: *const BspEngine,
        node_idx: NodeIndex,
        rect: Rect,
        inner_gap: f64,
        mins: *const MinSizes,
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
                // Split along the longer side so tiles stay close to square, unless only the other way fits.
                const preferred = rect.width >= rect.height;
                const parts = self.fitSplit(branch.left, branch.right, branch.ratio, rect, inner_gap, mins, preferred) orelse
                    self.fitSplit(branch.left, branch.right, branch.ratio, rect, inner_gap, mins, !preferred) orelse
                    splitRect(rect, preferred, inner_gap, @round(@max(0.0, if (preferred) rect.width - inner_gap else rect.height - inner_gap) * branch.ratio));

                self.renderNode(branch.left, parts[0], inner_gap, mins, max_count, out_ids, out_rects, count);
                self.renderNode(branch.right, parts[1], inner_gap, mins, max_count, out_ids, out_rects, count);
            },
            .empty => {},
        }
    }

    pub fn findNeighbor(
        self: *BspEngine,
        dir: Direction,
        screen_rect: Rect,
        gaps: GapConfig,
        mins: *const MinSizes,
    ) ?WindowId {
        const focused = self.focused_window orelse return null;

        if (self.layout_mode == .scrolling and !self.fullscreen) {
            const d = stripDelta(dir);
            return self.strip.neighbor(focused, d[0], d[1]);
        }

        var ids: [MAX_WINDOWS]WindowId = undefined;
        var rects: [MAX_WINDOWS]Rect = undefined;
        const count = self.calculateLayout(screen_rect, gaps, mins, MAX_WINDOWS, &ids, &rects);
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

    fn stripDelta(dir: Direction) [2]i8 {
        return switch (dir) {
            .left => .{ -1, 0 },
            .right => .{ 1, 0 },
            .up => .{ 0, -1 },
            .down => .{ 0, 1 },
        };
    }

    pub fn focusDirection(
        self: *BspEngine,
        dir: Direction,
        screen_rect: Rect,
        gaps: GapConfig,
        mins: *const MinSizes,
    ) ?WindowId {
        if (self.findNeighbor(dir, screen_rect, gaps, mins)) |target_wid| {
            self.setFocus(target_wid);
            return target_wid;
        }
        return null;
    }

    pub fn swapDirection(
        self: *BspEngine,
        dir: Direction,
        screen_rect: Rect,
        gaps: GapConfig,
        mins: *const MinSizes,
    ) bool {
        const focused = self.focused_window orelse return false;

        if (self.layout_mode == .scrolling) {
            const d = stripDelta(dir);
            return self.strip.move(focused, d[0], d[1]);
        }

        const target_wid = self.findNeighbor(dir, screen_rect, gaps, mins) orelse return false;

        const leaf1 = self.findLeafByWindow(focused);
        const leaf2 = self.findLeafByWindow(target_wid);
        if (leaf1 == null_node or leaf2 == null_node) return false;

        self.nodes[leaf1].data.leaf.window_id = target_wid;
        self.nodes[leaf2].data.leaf.window_id = focused;

        self.focused_window = focused;
        return true;
    }

    /// True when every tiled window gets at least its minimum size. Scrolling, monocle and fullscreen never
    /// squeeze windows, so they always fit.
    pub fn allFit(self: *BspEngine, screen_rect: Rect, gaps: GapConfig, mins: *const MinSizes) bool {
        if (self.fullscreen) return true;
        switch (self.layout_mode) {
            .monocle, .scrolling => return true,
            .dwindle, .master_stack => {},
        }
        var ids: [MAX_WINDOWS]WindowId = undefined;
        var rects: [MAX_WINDOWS]Rect = undefined;
        const n = self.calculateLayout(screen_rect, gaps, mins, MAX_WINDOWS, &ids, &rects);
        for (0..n) |i| {
            const m = mins.get(ids[i]);
            if (m.width > rects[i].width + 1 or m.height > rects[i].height + 1) return false;
        }
        return true;
    }

    /// Scrolling layout: steps the focused column through the preset widths.
    pub fn cycleColumnWidth(self: *BspEngine) void {
        const wid = self.focused_window orelse return;
        self.strip.cycleWidth(wid);
    }

    /// Scrolling layout: stacks the focused window into the column on that side, or pulls it out into its own.
    pub fn consumeOrExpel(self: *BspEngine, dir: Direction) bool {
        const wid = self.focused_window orelse return false;
        const d = stripDelta(dir);
        if (d[0] == 0) return false;
        return self.strip.consumeOrExpel(wid, d[0]);
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
        &MinSizes.empty,
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
        &MinSizes.empty,
        10,
        &ids,
        &rects,
    );
    try std.testing.expectEqual(@as(usize, 2), count2);
}

test "BspEngine splits follow tile shape after removals" {
    var engine = BspEngine.init();
    engine.addWindow(1);
    engine.addWindow(2); // 1 | 2
    engine.addWindow(3); // 1 | (2 / 3)
    engine.setFocus(1);
    engine.addWindow(4); // (1 / 4) | (2 / 3)
    engine.removeWindow(2); // (1 / 4) | 3

    var ids: [10]WindowId = undefined;
    var rects: [10]Rect = undefined;
    const count = engine.calculateLayout(
        .{ .x = 0, .y = 0, .width = 1000, .height = 500 },
        .{ .inner = 10, .outer = 0 },
        &MinSizes.empty,
        10,
        &ids,
        &rects,
    );
    try std.testing.expectEqual(@as(usize, 3), count);
    // The left half is tall, so 1 and 4 stack instead of becoming thin columns.
    try std.testing.expectEqual(@as(WindowId, 1), ids[0]);
    try std.testing.expectEqual(@as(WindowId, 4), ids[1]);
    try std.testing.expectEqual(rects[0].x, rects[1].x);
    try std.testing.expect(rects[1].y > rects[0].y);
}

test "BspEngine focus and swap directional" {
    var engine = BspEngine.init();
    engine.addWindow(1);
    engine.addWindow(2);

    const screen = Rect{ .x = 0, .y = 0, .width = 1000, .height = 500 };
    const gaps = GapConfig{ .inner = 10, .outer = 10 };

    const left_wid = engine.focusDirection(.left, screen, gaps, &MinSizes.empty);
    try std.testing.expectEqual(@as(?WindowId, 1), left_wid);
    try std.testing.expectEqual(@as(?WindowId, 1), engine.getFocus());

    const right_wid = engine.focusDirection(.right, screen, gaps, &MinSizes.empty);
    try std.testing.expectEqual(@as(?WindowId, 2), right_wid);

    const swapped = engine.swapDirection(.left, screen, gaps, &MinSizes.empty);
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
        &MinSizes.empty,
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
        &MinSizes.empty,
        10,
        &ids,
        &rects,
    );
    try std.testing.expectEqual(@as(usize, 1), count_fs);
}

test "BspEngine dwindle moves the divider for minimum widths" {
    var engine = BspEngine.init();
    engine.addWindow(1);
    engine.addWindow(2);
    var mins = MinSizes{};
    mins.set(1, .{ .width = 700 });

    var ids: [10]WindowId = undefined;
    var rects: [10]Rect = undefined;
    _ = engine.calculateLayout(.{ .x = 0, .y = 0, .width = 1000, .height = 500 }, .{ .inner = 10, .outer = 0 }, &mins, 10, &ids, &rects);
    try std.testing.expectEqual(@as(f64, 700), rects[0].width);
    try std.testing.expectEqual(@as(f64, 290), rects[1].width);
}

test "BspEngine dwindle stacks when side by side can't fit" {
    var engine = BspEngine.init();
    engine.addWindow(1);
    engine.addWindow(2);
    var mins = MinSizes{};
    mins.set(1, .{ .width = 600 });
    mins.set(2, .{ .width = 600 });

    var ids: [10]WindowId = undefined;
    var rects: [10]Rect = undefined;
    _ = engine.calculateLayout(.{ .x = 0, .y = 0, .width = 1000, .height = 500 }, .{ .inner = 10, .outer = 0 }, &mins, 10, &ids, &rects);
    try std.testing.expectEqual(rects[0].x, rects[1].x);
    try std.testing.expectEqual(@as(f64, 1000), rects[0].width);
    try std.testing.expect(rects[1].y > rects[0].y);
}

test "BspEngine scrolling layout navigation" {
    var engine = BspEngine.init();
    engine.layout_mode = .scrolling;
    engine.addWindow(1);
    engine.addWindow(2);
    engine.addWindow(3); // columns: 1 2 3, focus 3
    const screen = Rect{ .x = 0, .y = 0, .width = 1000, .height = 500 };
    const gaps = GapConfig{ .inner = 0, .outer = 0 };

    try std.testing.expectEqual(@as(?WindowId, 2), engine.focusDirection(.left, screen, gaps, &MinSizes.empty));
    try std.testing.expect(engine.consumeOrExpel(.left)); // columns: (1 / 2) 3
    try std.testing.expectEqual(@as(usize, 2), engine.strip.count);
    try std.testing.expectEqual(@as(?WindowId, 1), engine.focusDirection(.up, screen, gaps, &MinSizes.empty));
    try std.testing.expectEqual(@as(?WindowId, 3), engine.focusDirection(.right, screen, gaps, &MinSizes.empty));
    // Coming back to the stacked column lands on the window focused there last.
    try std.testing.expectEqual(@as(?WindowId, 1), engine.focusDirection(.left, screen, gaps, &MinSizes.empty));

    engine.removeWindow(1);
    try std.testing.expectEqual(@as(?WindowId, 2), engine.getFocus());

    var ids: [10]WindowId = undefined;
    var rects: [10]Rect = undefined;
    const count = engine.calculateLayout(screen, gaps, &MinSizes.empty, 10, &ids, &rects);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(f64, 500), rects[0].height); // back to a lone window, full height
}
