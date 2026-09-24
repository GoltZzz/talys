const std = @import("std");
const geometry = @import("geometry.zig");
const constraints = @import("constraints.zig");

const Rect = geometry.Rect;
const WindowHints = constraints.WindowHints;
pub const WindowId = constraints.WindowId;

// Smart layout: rather than one fixed recipe, arrangements are searched and scored against what each window
// wants (its minimum size, a preferred shape, a useful maximum width, a share of the screen) and against how
// far they'd move the windows already on screen. The best one wins, if it's clearly better than what's there.

/// Which way a branch cuts its rect. `auto` (what Dwindle builds) cuts along the longer side.
pub const Axis = enum(u8) { auto, side_by_side, stacked };

/// Most tiled windows Smart arranges; a workspace with more is laid out like Dwindle.
pub const MAX_LEAVES: usize = 12;
pub const MAX_TREE_NODES: usize = 2 * MAX_LEAVES - 1;
/// Up to this many windows every arrangement is tried; above it the current one is improved step by step.
pub const EXHAUSTIVE_LIMIT: usize = 5;
const SHAPE_NODES: usize = 2 * EXHAUSTIVE_LIMIT - 1;
const MAX_TRACKED: usize = 256;
pub const none: u8 = 0xFF;

// Scoring. Costs are small numbers per window; these weights set how much each wish counts.
/// Per window below its minimum size: anything that fits beats anything that doesn't.
const cost_misfit: f64 = 100.0;
const w_deficit: f64 = 100.0;
const w_aspect: f64 = 1.0;
/// Windows with no preferred shape still shouldn't become slivers.
const w_sliver: f64 = 2.0;
const sliver_min: f64 = 0.5;
const sliver_max: f64 = 2.6;
const w_share: f64 = 0.8;
const w_overwide: f64 = 1.0;
const w_move: f64 = 1.5;
/// Windows placed by hand resist being moved this many times harder.
const pin_factor: f64 = 8.0;
/// A new arrangement has to beat the current one by this much to replace it, so windows don't reshuffle for
/// tiny gains.
const switch_margin: f64 = 0.2;
const max_climb_steps = 24;

pub const Node = struct {
    /// Window of a leaf; while enumerating shapes, the leaf's slot.
    wid: WindowId = 0,
    axis: Axis = .auto,
    left: u8 = none,
    right: u8 = none,
    parent: u8 = none,

    pub fn isLeaf(self: Node) bool {
        return self.left == none;
    }
};

/// An arrangement as a binary tree of cuts, leaves being windows. Every node in `nodes[0..len]` is in the tree.
fn TreeOf(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        nodes: [capacity]Node = undefined,
        len: u8 = 0,
        root: u8 = none,

        pub fn addLeaf(self: *Self, wid: WindowId) ?u8 {
            if (self.len >= capacity) return null;
            const i = self.len;
            self.nodes[i] = .{ .wid = wid };
            self.len += 1;
            return i;
        }

        pub fn addBranch(self: *Self, axis: Axis, left: u8, right: u8) ?u8 {
            if (self.len >= capacity) return null;
            const i = self.len;
            self.nodes[i] = .{ .axis = axis, .left = left, .right = right };
            self.nodes[left].parent = i;
            self.nodes[right].parent = i;
            self.len += 1;
            return i;
        }

        pub fn leafCount(self: *const Self) usize {
            return (@as(usize, self.len) + 1) / 2;
        }

        fn replaceChild(self: *Self, parent: u8, old: u8, new: u8) void {
            if (parent == none) {
                self.root = new;
            } else if (self.nodes[parent].left == old) {
                self.nodes[parent].left = new;
            } else {
                self.nodes[parent].right = new;
            }
            self.nodes[new].parent = parent;
        }
    };
}

pub const Tree = TreeOf(MAX_TREE_NODES);
const Shape = TreeOf(SHAPE_NODES);

/// What the user set by hand on a workspace: size scales from resizing, pins from swaps and drops.
pub const Manual = struct {
    ids: [MAX_TRACKED]WindowId = undefined,
    scales: [MAX_TRACKED]f64 = undefined,
    pinned: [MAX_TRACKED]bool = undefined,
    count: usize = 0,

    fn find(self: *const Manual, wid: WindowId) ?usize {
        for (0..self.count) |i| {
            if (self.ids[i] == wid) return i;
        }
        return null;
    }

    fn slot(self: *Manual, wid: WindowId) ?usize {
        if (self.find(wid)) |i| return i;
        if (self.count >= MAX_TRACKED) return null;
        const i = self.count;
        self.ids[i] = wid;
        self.scales[i] = 1;
        self.pinned[i] = false;
        self.count += 1;
        return i;
    }

    pub fn scale(self: *const Manual, wid: WindowId) f64 {
        return if (self.find(wid)) |i| self.scales[i] else 1;
    }

    pub fn isPinned(self: *const Manual, wid: WindowId) bool {
        return if (self.find(wid)) |i| self.pinned[i] else false;
    }

    pub fn scaleBy(self: *Manual, wid: WindowId, factor: f64) void {
        const i = self.slot(wid) orelse return;
        self.scales[i] = std.math.clamp(self.scales[i] * factor, 0.25, 4.0);
    }

    pub fn pin(self: *Manual, wid: WindowId) void {
        const i = self.slot(wid) orelse return;
        self.pinned[i] = true;
    }

    pub fn remove(self: *Manual, wid: WindowId) void {
        const i = self.find(wid) orelse return;
        self.count -= 1;
        self.ids[i] = self.ids[self.count];
        self.scales[i] = self.scales[self.count];
        self.pinned[i] = self.pinned[self.count];
    }
};

/// Where each window was last put, so a new arrangement can be charged for moving them.
pub const Placement = struct {
    ids: [MAX_TRACKED]WindowId = undefined,
    rects: [MAX_TRACKED]Rect = undefined,
    count: usize = 0,

    pub fn get(self: *const Placement, wid: WindowId) ?Rect {
        for (0..self.count) |i| {
            if (self.ids[i] == wid) return self.rects[i];
        }
        return null;
    }

    pub fn record(self: *Placement, ids: [*]const WindowId, rects: [*]const Rect, n: usize) void {
        self.count = @min(n, MAX_TRACKED);
        for (0..self.count) |i| {
            self.ids[i] = ids[i];
            self.rects[i] = rects[i];
        }
    }
};

/// How the last search went; the host logs it.
pub const Stats = extern struct {
    cost: f64 = 0,
    baseline_cost: f64 = 0,
    evaluated: u32 = 0,
    /// Counts searches, so the host can tell a new one happened.
    searches: u32 = 0,
    changed: bool = false,
};

/// A workspace's Smart layout state.
pub const State = struct {
    manual: Manual = .{},
    prev: Placement = .{},
    /// Set when windows come or go; the arrangement is searched again on the next layout.
    dirty: bool = true,
    area: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    gap: f64 = -1,
    hints_version: u32 = 0,
    /// The last search found nothing that fits; searching again won't help until something changes.
    no_fit: bool = false,
    stats: Stats = .{},

    pub fn reset(self: *State) void {
        self.* = .{};
    }

    /// Whether the arrangement was made for other windows, another screen, other gaps or other hints.
    pub fn needsSearch(self: *const State, area: Rect, gap: f64, hints_version: u32) bool {
        return self.dirty or !std.meta.eql(self.area, area) or self.gap != gap or self.hints_version != hints_version;
    }

    pub fn searched(self: *State, result: *const Result, area: Rect, gap: f64, hints_version: u32) void {
        self.dirty = false;
        self.area = area;
        self.gap = gap;
        self.hints_version = hints_version;
        self.no_fit = !result.fits;
        self.stats = .{
            .cost = result.cost,
            .baseline_cost = result.baseline_cost,
            .evaluated = result.evaluated,
            .searches = self.stats.searches +% 1,
            .changed = result.changed,
        };
    }
};

pub const Context = struct {
    /// Screen minus the outer gap.
    area: Rect,
    gap: f64,
    hints: *const WindowHints,
    manual: *const Manual,
    prev: *const Placement,

    fn weight(self: Context, wid: WindowId) f64 {
        return @max(0.05, self.hints.getPrefs(wid).weight) * self.manual.scale(wid);
    }

    /// Useful maximum width; never below the window's minimum.
    fn cap(self: Context, wid: WindowId) f64 {
        const max_width = self.hints.getPrefs(wid).max_width;
        if (max_width <= 0) return std.math.inf(f64);
        return @max(max_width, self.hints.tile(wid).width);
    }
};

pub const Score = struct {
    cost: f64,
    fits: bool,
};

/// Cuts `rect` in two along its width (`side_by_side`) or height, the first part `first` long.
pub fn cut(rect: Rect, side_by_side: bool, gap: f64, first: f64) [2]Rect {
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

/// Length of the first of two parts sharing `total`: by weight, but each gets its minimum and neither grows
/// past its cap while the other still has use for the room. When the minimums can't both fit, they're squeezed
/// in proportion.
fn share(total: f64, min_a: f64, min_b: f64, cap_a: f64, cap_b: f64, weight_a: f64, weight_b: f64) f64 {
    const need = min_a + min_b;
    if (need > total) return if (need > 0) @round(total * min_a / need) else @round(total / 2);

    const frac = weight_a / (weight_a + weight_b);
    var a = total * frac;
    const spare = total - cap_a - cap_b;
    if (spare > 0) {
        a = cap_a + spare * frac;
    } else if (a > cap_a) {
        a = cap_a;
    } else if (total - a > cap_b) {
        a = total - cap_b;
    }
    return std.math.clamp(@round(a), min_a, total - min_b);
}

const Extent = struct {
    min_w: f64,
    min_h: f64,
    cap_w: f64,
    weight: f64,
};

fn measure(tree: *const Tree, idx: u8, ctx: Context, ext: *[MAX_TREE_NODES]Extent) Extent {
    const node = tree.nodes[idx];
    const e: Extent = if (node.isLeaf()) blk: {
        const m = ctx.hints.tile(node.wid);
        break :blk .{ .min_w = m.width, .min_h = m.height, .cap_w = ctx.cap(node.wid), .weight = ctx.weight(node.wid) };
    } else blk: {
        const a = measure(tree, node.left, ctx, ext);
        const b = measure(tree, node.right, ctx, ext);
        break :blk if (node.axis == .stacked) .{
            .min_w = @max(a.min_w, b.min_w),
            .min_h = a.min_h + ctx.gap + b.min_h,
            .cap_w = @max(a.cap_w, b.cap_w),
            .weight = a.weight + b.weight,
        } else .{
            .min_w = a.min_w + ctx.gap + b.min_w,
            .min_h = @max(a.min_h, b.min_h),
            .cap_w = a.cap_w + ctx.gap + b.cap_w,
            .weight = a.weight + b.weight,
        };
    };
    ext[idx] = e;
    return e;
}

fn place(tree: *const Tree, idx: u8, rect: Rect, gap: f64, ext: *const [MAX_TREE_NODES]Extent, rects: *[MAX_TREE_NODES]Rect) void {
    rects[idx] = rect;
    const node = tree.nodes[idx];
    if (node.isLeaf()) return;
    const a = ext[node.left];
    const b = ext[node.right];
    const side_by_side = node.axis != .stacked;
    const total = @max(0.0, (if (side_by_side) rect.width else rect.height) - gap);
    const first = if (side_by_side)
        share(total, a.min_w, b.min_w, a.cap_w, b.cap_w, a.weight, b.weight)
    else
        share(total, a.min_h, b.min_h, std.math.inf(f64), std.math.inf(f64), a.weight, b.weight);
    const parts = cut(rect, side_by_side, gap, first);
    place(tree, node.left, parts[0], gap, ext, rects);
    place(tree, node.right, parts[1], gap, ext, rects);
}

/// Gives every node of `tree` its rect in `ctx.area`. Branches must have an axis (see `resolveAxes`).
pub fn arrange(tree: *const Tree, ctx: Context, rects: *[MAX_TREE_NODES]Rect) void {
    if (tree.root == none) return;
    var ext: [MAX_TREE_NODES]Extent = undefined;
    _ = measure(tree, tree.root, ctx, &ext);
    place(tree, tree.root, ctx.area, ctx.gap, &ext, rects);
}

/// How well an arranged tree suits its windows; lower is better.
pub fn score(tree: *const Tree, ctx: Context, rects: *const [MAX_TREE_NODES]Rect) Score {
    var total_weight: f64 = 0;
    var total_area: f64 = 0;
    for (tree.nodes[0..tree.len], 0..) |node, i| {
        if (!node.isLeaf()) continue;
        total_weight += ctx.weight(node.wid);
        total_area += rects[i].width * rects[i].height;
    }

    const span = ctx.area.width + ctx.area.height;
    var cost: f64 = 0;
    var fits = true;
    for (tree.nodes[0..tree.len], 0..) |node, i| {
        if (!node.isLeaf()) continue;
        const r = rects[i];
        const m = ctx.hints.tile(node.wid);
        const prefs = ctx.hints.getPrefs(node.wid);

        const deficit = @max(0.0, m.width - r.width) + @max(0.0, m.height - r.height);
        if (deficit > 0.5) {
            fits = false;
            cost += cost_misfit + w_deficit * deficit / span;
        }
        if (r.width < 1 or r.height < 1) continue;

        const aspect = r.width / r.height;
        if (prefs.aspect > 0) {
            const d = @log(aspect / prefs.aspect);
            cost += w_aspect * d * d;
        } else {
            const d = @log(aspect / std.math.clamp(aspect, sliver_min, sliver_max));
            cost += w_sliver * d * d;
        }

        const cap = ctx.cap(node.wid);
        if (r.width > cap) {
            const over = (r.width - cap) / cap;
            cost += w_overwide * over * over;
        }

        // A window at its useful width isn't short-changed by having less area than its weight asks for.
        const target = ctx.weight(node.wid) / total_weight;
        const actual = r.width * r.height / total_area;
        if (!(actual < target and r.width >= cap - 1)) {
            const d = @log(actual / target);
            cost += w_share * d * d;
        }

        if (ctx.prev.get(node.wid)) |p| {
            const moved = (@abs(r.x - p.x) + @abs(r.y - p.y) + @abs(r.width - p.width) + @abs(r.height - p.height)) / span;
            cost += w_move * moved * (if (ctx.manual.isPinned(node.wid)) pin_factor else 1.0);
        }
    }
    return .{ .cost = cost, .fits = fits };
}

pub fn evaluate(tree: *const Tree, ctx: Context, rects: *[MAX_TREE_NODES]Rect) Score {
    arrange(tree, ctx, rects);
    return score(tree, ctx, rects);
}

fn subtreeWeight(tree: *const Tree, idx: u8, ctx: Context) f64 {
    const node = tree.nodes[idx];
    if (node.isLeaf()) return ctx.weight(node.wid);
    return subtreeWeight(tree, node.left, ctx) + subtreeWeight(tree, node.right, ctx);
}

fn resolveFrom(tree: *Tree, idx: u8, rect: Rect, ctx: Context) void {
    const node = &tree.nodes[idx];
    if (node.isLeaf()) return;
    if (node.axis == .auto) node.axis = if (rect.width >= rect.height) .side_by_side else .stacked;
    const side_by_side = node.axis == .side_by_side;
    const wl = subtreeWeight(tree, node.left, ctx);
    const wr = subtreeWeight(tree, node.right, ctx);
    const total = @max(0.0, (if (side_by_side) rect.width else rect.height) - ctx.gap);
    const parts = cut(rect, side_by_side, ctx.gap, @round(total * wl / (wl + wr)));
    resolveFrom(tree, node.left, parts[0], ctx);
    resolveFrom(tree, node.right, parts[1], ctx);
}

/// Picks a direction for every `auto` branch, as Dwindle would: along the longer side of the rect it gets.
pub fn resolveAxes(tree: *Tree, ctx: Context) void {
    if (tree.root != none) resolveFrom(tree, tree.root, ctx.area, ctx);
}

pub const Result = struct {
    tree: Tree,
    cost: f64,
    baseline_cost: f64,
    evaluated: u32,
    /// Whether `tree` differs from the baseline.
    changed: bool,
    fits: bool,
};

const Candidate = struct {
    tree: Tree,
    cost: f64,
};

const Search = struct {
    ctx: Context,
    best: Candidate,
    evaluated: u32 = 0,
    rects: [MAX_TREE_NODES]Rect = undefined,

    fn consider(self: *Search, tree: *const Tree) void {
        const cost = evaluate(tree, self.ctx, &self.rects).cost;
        self.evaluated += 1;
        if (cost < self.best.cost - 1e-9) self.best = .{ .tree = tree.*, .cost = cost };
    }
};

/// Searches for the best arrangement of the windows in `baseline` (the one on screen, windows added or removed
/// since included). Keeps the baseline unless something beats it by `switch_margin`.
pub fn optimize(baseline: *const Tree, ctx: Context) Result {
    var rects: [MAX_TREE_NODES]Rect = undefined;
    const base = evaluate(baseline, ctx, &rects);
    const base_cost = base.cost;
    var search = Search{ .ctx = ctx, .best = .{ .tree = baseline.*, .cost = base_cost }, .evaluated = 1 };

    const n = baseline.leafCount();
    if (n >= 2 and n <= EXHAUSTIVE_LIMIT) {
        tryEverything(baseline, &search);
    } else if (n > EXHAUSTIVE_LIMIT) {
        climb(&search);
    }

    const changed = search.best.cost + switch_margin < base_cost;
    const fits = if (changed) evaluate(&search.best.tree, ctx, &rects).fits else base.fits;
    return .{
        .tree = if (changed) search.best.tree else baseline.*,
        .cost = if (changed) search.best.cost else base_cost,
        .baseline_cost = base_cost,
        .evaluated = search.evaluated,
        .changed = changed,
        .fits = fits,
    };
}

// Exhaustive search: every shape of cuts, with every order of windows in it.

const ShapeList = struct {
    items: [128]Shape = undefined,
    len: usize = 0,
};

/// Every tree of `n` leaves (slots 0..n-1 in order) with directed cuts, whose root isn't a `forbid` cut.
/// A cut's right child never cuts the same way, since A|(B|C) and (A|B)|C are the same arrangement.
fn shapesOf(n: usize, forbid: Axis) ShapeList {
    var out = ShapeList{};
    if (n == 1) {
        var leaf = Shape{};
        leaf.root = leaf.addLeaf(0).?;
        out.items[0] = leaf;
        out.len = 1;
        return out;
    }
    for (1..n) |left_leaves| {
        for ([_]Axis{ .side_by_side, .stacked }) |axis| {
            if (axis == forbid) continue;
            const lefts = shapesOf(left_leaves, .auto);
            const rights = shapesOf(n - left_leaves, axis);
            for (lefts.items[0..lefts.len]) |l| {
                for (rights.items[0..rights.len]) |r| {
                    out.items[out.len] = join(l, r, axis, left_leaves);
                    out.len += 1;
                }
            }
        }
    }
    return out;
}

fn join(l: Shape, r: Shape, axis: Axis, left_leaves: usize) Shape {
    var s = l;
    const offset = l.len;
    for (r.nodes[0..r.len]) |node| {
        var copy = node;
        if (copy.isLeaf()) {
            copy.wid += @intCast(left_leaves);
        } else {
            copy.left += offset;
            copy.right += offset;
        }
        if (copy.parent != none) copy.parent += offset;
        s.nodes[s.len] = copy;
        s.len += 1;
    }
    s.root = s.addBranch(axis, l.root, r.root + offset).?;
    return s;
}

const shape_tables = blk: {
    @setEvalBranchQuota(10_000_000);
    var tables: [EXHAUSTIVE_LIMIT + 1]ShapeList = undefined;
    for (1..EXHAUSTIVE_LIMIT + 1) |n| tables[n] = shapesOf(n, .auto);
    break :blk tables;
};

fn tryShapes(order: []const WindowId, search: *Search) void {
    const table = &shape_tables[order.len];
    for (table.items[0..table.len]) |shape| {
        var tree = Tree{ .len = shape.len, .root = shape.root };
        for (shape.nodes[0..shape.len], 0..) |node, i| {
            tree.nodes[i] = node;
            if (node.isLeaf()) tree.nodes[i].wid = order[node.wid];
        }
        search.consider(&tree);
    }
}

fn tryEverything(baseline: *const Tree, search: *Search) void {
    var order: [EXHAUSTIVE_LIMIT]WindowId = undefined;
    var n: usize = 0;
    for (baseline.nodes[0..baseline.len]) |node| {
        if (node.isLeaf()) {
            order[n] = node.wid;
            n += 1;
        }
    }

    // Heap's algorithm: every order of the windows.
    var c = [_]usize{0} ** EXHAUSTIVE_LIMIT;
    tryShapes(order[0..n], search);
    var i: usize = 1;
    while (i < n) {
        if (c[i] < i) {
            const j = if (i % 2 == 0) 0 else c[i];
            std.mem.swap(WindowId, &order[j], &order[i]);
            tryShapes(order[0..n], search);
            c[i] += 1;
            i = 1;
        } else {
            c[i] = 0;
            i += 1;
        }
    }
}

// Local search for bigger workspaces: from the current arrangement, keep taking the best single change
// (swap two windows, turn a cut, or move a window next to another part of the tree) while it helps.

/// Detaches leaf `leaf` and puts it beside `target`, `axis` apart, first or second. False when that's no move.
fn regraft(tree: *Tree, leaf: u8, target: u8, axis: Axis, leaf_first: bool) bool {
    const parent = tree.nodes[leaf].parent;
    if (parent == none or target == leaf or target == parent) return false;

    const p = tree.nodes[parent];
    const sibling = if (p.left == leaf) p.right else p.left;
    tree.replaceChild(p.parent, parent, sibling);

    const target_parent = tree.nodes[target].parent;
    tree.nodes[parent] = .{
        .axis = axis,
        .left = if (leaf_first) leaf else target,
        .right = if (leaf_first) target else leaf,
    };
    tree.replaceChild(target_parent, target, parent);
    tree.nodes[target].parent = parent;
    tree.nodes[leaf].parent = parent;
    return true;
}

fn climb(search: *Search) void {
    var steps: usize = 0;
    while (steps < max_climb_steps) : (steps += 1) {
        const from = search.best;
        const len = from.tree.len;

        for (0..len) |a| {
            if (!from.tree.nodes[a].isLeaf()) continue;
            for (a + 1..len) |b| {
                if (!from.tree.nodes[b].isLeaf()) continue;
                var t = from.tree;
                std.mem.swap(WindowId, &t.nodes[a].wid, &t.nodes[b].wid);
                search.consider(&t);
            }
        }

        for (0..len) |i| {
            if (from.tree.nodes[i].isLeaf()) continue;
            var t = from.tree;
            t.nodes[i].axis = if (t.nodes[i].axis == .stacked) .side_by_side else .stacked;
            search.consider(&t);
        }

        for (0..len) |leaf| {
            if (!from.tree.nodes[leaf].isLeaf()) continue;
            for (0..len) |target| {
                for ([_]Axis{ .side_by_side, .stacked }) |axis| {
                    for ([_]bool{ true, false }) |leaf_first| {
                        var t = from.tree;
                        if (regraft(&t, @intCast(leaf), @intCast(target), axis, leaf_first)) search.consider(&t);
                    }
                }
            }
        }

        if (search.best.cost >= from.cost - 1e-9) return;
    }
}

// Tests

fn testContext(area: Rect, hints: *const WindowHints, manual: *const Manual, prev: *const Placement) Context {
    return .{ .area = area, .gap = 8, .hints = hints, .manual = manual, .prev = prev };
}

fn chain(wids: []const WindowId, axis: Axis) Tree {
    var t = Tree{};
    var root = t.addLeaf(wids[0]).?;
    for (wids[1..]) |w| {
        const leaf = t.addLeaf(w).?;
        root = t.addBranch(axis, root, leaf).?;
    }
    t.root = root;
    return t;
}

fn leafRect(tree: *const Tree, rects: *const [MAX_TREE_NODES]Rect, wid: WindowId) Rect {
    for (tree.nodes[0..tree.len], 0..) |node, i| {
        if (node.isLeaf() and node.wid == wid) return rects[i];
    }
    unreachable;
}

fn expectSane(tree: *const Tree, rects: *const [MAX_TREE_NODES]Rect, area: Rect) !void {
    for (tree.nodes[0..tree.len], 0..) |a, i| {
        if (!a.isLeaf()) continue;
        const r = rects[i];
        try std.testing.expect(r.x >= area.x - 0.5 and r.y >= area.y - 0.5);
        try std.testing.expect(r.x + r.width <= area.x + area.width + 0.5);
        try std.testing.expect(r.y + r.height <= area.y + area.height + 0.5);
        for (tree.nodes[0..tree.len], 0..) |b, j| {
            if (!b.isLeaf() or j <= i) continue;
            const q = rects[j];
            const overlap_w = @min(r.x + r.width, q.x + q.width) - @max(r.x, q.x);
            const overlap_h = @min(r.y + r.height, q.y + q.height) - @max(r.y, q.y);
            try std.testing.expect(overlap_w <= 0.5 or overlap_h <= 0.5);
        }
    }
}

test "shape tables count every distinct arrangement" {
    // Large Schröder numbers: slicing floorplans of n rooms in a fixed order.
    const want = [_]usize{ 0, 1, 2, 6, 22, 90 };
    for (1..EXHAUSTIVE_LIMIT + 1) |n| try std.testing.expectEqual(want[n], shape_tables[n].len);
}

test "share respects minimums, caps and weights" {
    const inf = std.math.inf(f64);
    try std.testing.expectEqual(@as(f64, 500), share(1000, 0, 0, inf, inf, 1, 1));
    try std.testing.expectEqual(@as(f64, 700), share(1000, 700, 0, inf, inf, 1, 1));
    try std.testing.expectEqual(@as(f64, 400), share(1000, 0, 0, 400, inf, 1, 1));
    try std.testing.expectEqual(@as(f64, 750), share(1000, 0, 0, inf, inf, 3, 1));
    // Both capped: the spare room is shared by weight.
    try std.testing.expectEqual(@as(f64, 500), share(1000, 0, 0, 300, 300, 1, 1));
    // Minimums that can't both fit are squeezed in proportion.
    try std.testing.expectEqual(@as(f64, 500), share(1000, 600, 600, inf, inf, 1, 1));
}

test "smart gives a tall-loving terminal a column" {
    // Browser, terminal and chat on a 1512×982 MacBook screen.
    const area = Rect{ .x = 10, .y = 44, .width = 1492, .height = 928 };
    var hints = WindowHints{};
    hints.set(1, .{ .width = 626, .height = 469 });
    hints.setPrefs(1, .{ .max_width = 1600, .weight = 1.3 });
    hints.setPrefs(2, .{ .aspect = 0.7 });
    hints.setPrefs(3, .{ .weight = 0.6 });
    const manual = Manual{};
    const prev = Placement{};
    const ctx = testContext(area, &hints, &manual, &prev);

    var baseline = chain(&.{ 1, 2, 3 }, .auto);
    resolveAxes(&baseline, ctx);
    const result = optimize(&baseline, ctx);
    try std.testing.expect(result.evaluated > 1);

    var rects: [MAX_TREE_NODES]Rect = undefined;
    const s = evaluate(&result.tree, ctx, &rects);
    try std.testing.expect(s.fits);
    try expectSane(&result.tree, &rects, area);
    const term = leafRect(&result.tree, &rects, 2);
    try std.testing.expect(term.width < term.height);
    const browser = leafRect(&result.tree, &rects, 1);
    try std.testing.expect(browser.width * browser.height > term.width * term.height);
}

test "smart keeps a settled arrangement" {
    const area = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    var hints = WindowHints{};
    hints.setPrefs(2, .{ .aspect = 0.7 });
    const manual = Manual{};
    var prev = Placement{};
    const ctx = testContext(area, &hints, &manual, &prev);

    var baseline = chain(&.{ 1, 2, 3, 4 }, .auto);
    resolveAxes(&baseline, ctx);
    const first = optimize(&baseline, ctx);

    var rects: [MAX_TREE_NODES]Rect = undefined;
    arrange(&first.tree, ctx, &rects);
    var ids: [4]WindowId = undefined;
    var out: [4]Rect = undefined;
    var n: usize = 0;
    for (first.tree.nodes[0..first.tree.len], 0..) |node, i| {
        if (!node.isLeaf()) continue;
        ids[n] = node.wid;
        out[n] = rects[i];
        n += 1;
    }
    prev.record(&ids, &out, n);

    const again = optimize(&first.tree, ctx);
    try std.testing.expect(!again.changed);
}

test "smart fits windows Dwindle can't" {
    // Two windows that are each too wide to share the screen side by side, and a third.
    const area = Rect{ .x = 0, .y = 0, .width = 1000, .height = 1000 };
    var hints = WindowHints{};
    hints.set(1, .{ .width = 600, .height = 300 });
    hints.set(2, .{ .width = 600, .height = 300 });
    hints.set(3, .{ .width = 300, .height = 600 });
    const manual = Manual{};
    const prev = Placement{};
    const ctx = testContext(area, &hints, &manual, &prev);

    var baseline = chain(&.{ 1, 2, 3 }, .side_by_side);
    const result = optimize(&baseline, ctx);
    try std.testing.expect(result.changed);
    var rects: [MAX_TREE_NODES]Rect = undefined;
    try std.testing.expect(evaluate(&result.tree, ctx, &rects).fits);
    try expectSane(&result.tree, &rects, area);
}

test "smart improves big workspaces step by step" {
    const area = Rect{ .x = 0, .y = 0, .width = 3440, .height = 1440 };
    var hints = WindowHints{};
    for (1..11) |w| hints.setPrefs(@intCast(w), .{ .aspect = if (w % 2 == 0) 0.7 else 1.6 });
    const manual = Manual{};
    const prev = Placement{};
    const ctx = testContext(area, &hints, &manual, &prev);

    var baseline = chain(&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, .side_by_side);
    const result = optimize(&baseline, ctx);
    try std.testing.expect(result.changed);
    try std.testing.expect(result.cost < result.baseline_cost);
    var rects: [MAX_TREE_NODES]Rect = undefined;
    try std.testing.expect(evaluate(&result.tree, ctx, &rects).fits);
    try expectSane(&result.tree, &rects, area);
    try std.testing.expectEqual(@as(usize, 10), result.tree.leafCount());
}

test "regraft keeps a well-formed tree" {
    var t = chain(&.{ 1, 2, 3, 4 }, .side_by_side);
    // Leaves are at 0, 1, 3, 5; move window 1 next to window 4.
    try std.testing.expect(regraft(&t, 0, 5, .stacked, true));
    var leaves: usize = 0;
    var roots: usize = 0;
    for (t.nodes[0..t.len], 0..) |node, i| {
        if (node.isLeaf()) leaves += 1;
        if (node.parent == none) {
            roots += 1;
            try std.testing.expectEqual(t.root, @as(u8, @intCast(i)));
        } else {
            const p = t.nodes[node.parent];
            try std.testing.expect(p.left == i or p.right == i);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), leaves);
    try std.testing.expectEqual(@as(usize, 1), roots);
}
