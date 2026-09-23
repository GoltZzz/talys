const std = @import("std");

pub const WindowId = u32;
pub const MAX_ENTRIES: usize = 512;

pub const Size = struct {
    width: f64 = 0,
    height: f64 = 0,
};

/// Smallest size each window's app accepts, as learned by the host (0 = unknown / no limit).
pub const MinSizes = struct {
    ids: [MAX_ENTRIES]WindowId = undefined,
    sizes: [MAX_ENTRIES]Size = undefined,
    count: usize = 0,

    pub const empty = MinSizes{};

    pub fn reset(self: *MinSizes) void {
        self.count = 0;
    }

    pub fn get(self: *const MinSizes, wid: WindowId) Size {
        for (0..self.count) |i| {
            if (self.ids[i] == wid) return self.sizes[i];
        }
        return .{};
    }

    pub fn set(self: *MinSizes, wid: WindowId, size: Size) void {
        for (0..self.count) |i| {
            if (self.ids[i] == wid) {
                self.sizes[i] = size;
                return;
            }
        }
        if (self.count >= MAX_ENTRIES) return;
        self.ids[self.count] = wid;
        self.sizes[self.count] = size;
        self.count += 1;
    }

    pub fn remove(self: *MinSizes, wid: WindowId) void {
        for (0..self.count) |i| {
            if (self.ids[i] == wid) {
                self.count -= 1;
                self.ids[i] = self.ids[self.count];
                self.sizes[i] = self.sizes[self.count];
                return;
            }
        }
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

test "MinSizes set, get, remove" {
    var mins = MinSizes{};
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
