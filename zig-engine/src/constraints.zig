const std = @import("std");

pub const WindowId = u32;
pub const MAX_ENTRIES: usize = 512;

pub const Size = struct {
    width: f64 = 0,
    height: f64 = 0,
};

/// Smallest tile any window gets, whatever its app reports: one whose real minimum isn't known yet must not be
/// squeezed into a sliver it can't actually shrink to, where it ends up hidden behind its neighbour.
pub const min_tile = Size{ .width = 300, .height = 150 };

/// Layout preferences for one window, which the Smart layout scores arrangements against.
pub const Prefs = struct {
    /// Preferred width ÷ height; 0 = none.
    aspect: f64 = 0,
    /// Width past which the window just wastes space; 0 = none.
    max_width: f64 = 0,
    /// Share of the screen relative to other windows.
    weight: f64 = 1,
};

/// What the host knows about each window: the smallest size its app accepts (0 = unknown / no limit) and its
/// layout preferences.
pub const WindowHints = struct {
    ids: [MAX_ENTRIES]WindowId = undefined,
    sizes: [MAX_ENTRIES]Size = undefined,
    prefs: [MAX_ENTRIES]Prefs = undefined,
    count: usize = 0,
    /// Bumped on every change, so a layout can tell it was arranged with hints that have since changed.
    version: u32 = 0,

    pub const empty = WindowHints{};

    pub fn reset(self: *WindowHints) void {
        self.count = 0;
        self.version +%= 1;
    }

    fn find(self: *const WindowHints, wid: WindowId) ?usize {
        for (0..self.count) |i| {
            if (self.ids[i] == wid) return i;
        }
        return null;
    }

    /// The window's entry, created with no hints when it has none yet.
    fn slot(self: *WindowHints, wid: WindowId) ?usize {
        if (self.find(wid)) |i| return i;
        if (self.count >= MAX_ENTRIES) return null;
        const i = self.count;
        self.ids[i] = wid;
        self.sizes[i] = .{};
        self.prefs[i] = .{};
        self.count += 1;
        return i;
    }

    pub fn get(self: *const WindowHints, wid: WindowId) Size {
        return if (self.find(wid)) |i| self.sizes[i] else .{};
    }

    /// The window's minimum, raised to `min_tile`: what a tile must give it.
    pub fn tile(self: *const WindowHints, wid: WindowId) Size {
        const m = self.get(wid);
        return .{ .width = @max(m.width, min_tile.width), .height = @max(m.height, min_tile.height) };
    }

    pub fn set(self: *WindowHints, wid: WindowId, size: Size) void {
        const i = self.slot(wid) orelse return;
        if (std.meta.eql(self.sizes[i], size)) return;
        self.sizes[i] = size;
        self.version +%= 1;
    }

    pub fn getPrefs(self: *const WindowHints, wid: WindowId) Prefs {
        return if (self.find(wid)) |i| self.prefs[i] else .{};
    }

    pub fn setPrefs(self: *WindowHints, wid: WindowId, prefs: Prefs) void {
        const i = self.slot(wid) orelse return;
        if (std.meta.eql(self.prefs[i], prefs)) return;
        self.prefs[i] = prefs;
        self.version +%= 1;
    }

    pub fn remove(self: *WindowHints, wid: WindowId) void {
        const i = self.find(wid) orelse return;
        self.count -= 1;
        self.ids[i] = self.ids[self.count];
        self.sizes[i] = self.sizes[self.count];
        self.prefs[i] = self.prefs[self.count];
        self.version +%= 1;
    }
};

/// Splits `total` into `mins.len` slots separated by `gap`, as evenly as the minimums allow: slots that
/// would get less than their minimum get exactly that, and the rest share what's left. Returns false (and
/// an even split) when the minimums can't all fit.
pub fn distribute(total: f64, gap: f64, mins: []const f64, out: []f64) bool {
    const n = mins.len;
    if (n == 0) return true;
    const avail = @max(0.0, total - gap * @as(f64, @floatFromInt(n - 1)));

    var min_sum: f64 = 0;
    for (mins) |m| min_sum += m;
    if (min_sum > avail + 0.5) {
        const even = @floor(avail / @as(f64, @floatFromInt(n)));
        for (0..n) |i| out[i] = even;
        return false;
    }

    // Pin the slots whose minimum exceeds the running fair share until the share stops changing.
    var pinned = [_]bool{false} ** 256;
    const limit = @min(n, pinned.len);
    var share: f64 = 0;
    while (true) {
        var free_total = avail;
        var free_count: usize = 0;
        for (0..limit) |i| {
            if (pinned[i]) free_total -= mins[i] else free_count += 1;
        }
        if (free_count == 0) break;
        share = free_total / @as(f64, @floatFromInt(free_count));
        var changed = false;
        for (0..limit) |i| {
            if (!pinned[i] and mins[i] > share) {
                pinned[i] = true;
                changed = true;
            }
        }
        if (!changed) break;
    }

    // Whole points, with any rounding remainder going to the last slot.
    var used: f64 = 0;
    for (0..n) |i| {
        out[i] = if (i < limit and pinned[i]) mins[i] else @floor(share);
        used += out[i];
    }
    out[n - 1] += avail - used;
    return true;
}

test "WindowHints set, get, remove" {
    var mins = WindowHints{};
    mins.set(1, .{ .width = 500, .height = 300 });
    mins.set(2, .{ .width = 200 });
    try std.testing.expectEqual(@as(f64, 500), mins.get(1).width);
    mins.set(1, .{ .width = 600 });
    try std.testing.expectEqual(@as(f64, 600), mins.get(1).width);
    mins.remove(1);
    try std.testing.expectEqual(@as(f64, 0), mins.get(1).width);
    try std.testing.expectEqual(@as(f64, 200), mins.get(2).width);
}

test "distribute respects minimums" {
    var out: [3]f64 = undefined;
    try std.testing.expect(distribute(1000, 10, &.{ 0, 600, 0 }, &out));
    try std.testing.expectEqual(@as(f64, 600), out[1]);
    try std.testing.expectEqual(@as(f64, 980), out[0] + out[1] + out[2]);
    try std.testing.expect(out[0] >= 180 and out[2] >= 180);

    try std.testing.expect(!distribute(1000, 10, &.{ 600, 600 }, out[0..2]));
}
