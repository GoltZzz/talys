const std = @import("std");
const geometry = @import("geometry.zig");
const constraints = @import("constraints.zig");
const Rect = geometry.Rect;
const GapConfig = geometry.GapConfig;
const WindowHints = constraints.WindowHints;

pub const WindowId = constraints.WindowId;
pub const MAX_COLUMNS: usize = 128;
pub const MAX_COLUMN_WINDOWS: usize = 8;

/// Column widths `cycleWidth` steps through, as fractions of the usable screen width.
pub const width_presets = [_]f64{ 1.0 / 3.0, 0.5, 2.0 / 3.0 };
const default_width: f64 = 0.5;

pub const Column = struct {
    windows: [MAX_COLUMN_WINDOWS]WindowId = undefined,
    count: usize = 0,
    /// Row that was focused last, so coming back to the column lands on it.
    active: usize = 0,
    /// Fraction of the usable screen width; never narrower than the widest window's minimum.
    width: f64 = default_width,

    fn removeAt(self: *Column, row: usize) void {
        for (row..self.count - 1) |i| self.windows[i] = self.windows[i + 1];
        self.count -= 1;
        if (self.active >= self.count and self.count > 0) self.active = self.count - 1;
    }
};

pub const Position = struct {
    col: usize,
    row: usize,
};

/// niri-style scrolling layout: an endless horizontal strip of columns, each holding one or more windows
/// stacked vertically. Windows keep a comfortable width however many there are; the view scrolls to
/// whichever column has focus.
pub const ScrollStrip = struct {
    columns: [MAX_COLUMNS]Column = undefined,
    count: usize = 0,
    /// Left edge of the view, in strip coordinates.
    view_x: f64 = 0,

    pub fn reset(self: *ScrollStrip) void {
        self.count = 0;
        self.view_x = 0;
    }

    pub fn find(self: *const ScrollStrip, wid: WindowId) ?Position {
        for (0..self.count) |c| {
            const col = &self.columns[c];
            for (0..col.count) |r| {
                if (col.windows[r] == wid) return .{ .col = c, .row = r };
            }
        }
        return null;
    }

    /// Opens a new column for `wid` at index `at` (clamped to the end).
    pub fn insertColumn(self: *ScrollStrip, at: usize, wid: WindowId) void {
        if (self.count >= MAX_COLUMNS) return;
        const idx = @min(at, self.count);
        var i = self.count;
        while (i > idx) : (i -= 1) self.columns[i] = self.columns[i - 1];
        self.columns[idx] = Column{};
        self.columns[idx].windows[0] = wid;
        self.columns[idx].count = 1;
        self.count += 1;
    }

    fn removeColumn(self: *ScrollStrip, idx: usize) void {
        for (idx..self.count - 1) |i| self.columns[i] = self.columns[i + 1];
        self.count -= 1;
    }

    pub fn remove(self: *ScrollStrip, wid: WindowId) void {
        const pos = self.find(wid) orelse return;
        const col = &self.columns[pos.col];
        col.removeAt(pos.row);
        if (col.count == 0) self.removeColumn(pos.col);
    }

    /// Where focus should go once `wid` leaves: the next window in its column, else the column that
    /// slides into its place, else the one before it.
    pub fn successor(self: *const ScrollStrip, wid: WindowId) ?WindowId {
        const pos = self.find(wid) orelse return null;
        const col = &self.columns[pos.col];
        if (col.count > 1) {
            const row = if (pos.row + 1 < col.count) pos.row + 1 else pos.row - 1;
            return col.windows[row];
        }
        if (pos.col + 1 < self.count) return self.activeWindow(pos.col + 1);
        if (pos.col > 0) return self.activeWindow(pos.col - 1);
        return null;
    }

    pub fn activeWindow(self: *const ScrollStrip, c: usize) WindowId {
        const col = &self.columns[c];
        return col.windows[@min(col.active, col.count - 1)];
    }

    pub fn markActive(self: *ScrollStrip, wid: WindowId) void {
        const pos = self.find(wid) orelse return;
        self.columns[pos.col].active = pos.row;
    }

    /// Neighbour of `wid`: left/right move between columns, up/down within one.
    pub fn neighbor(self: *const ScrollStrip, wid: WindowId, dx: i8, dy: i8) ?WindowId {
        const pos = self.find(wid) orelse return null;
        if (dx != 0) {
            const c = @as(i64, @intCast(pos.col)) + dx;
            if (c < 0 or c >= self.count) return null;
            return self.activeWindow(@intCast(c));
        }
        const col = &self.columns[pos.col];
        const r = @as(i64, @intCast(pos.row)) + dy;
        if (r < 0 or r >= col.count) return null;
        return col.windows[@intCast(r)];
    }

    /// Trades the slots of two windows, wherever they sit in the strip.
    pub fn swapWindows(self: *ScrollStrip, a: WindowId, b: WindowId) void {
        const pa = self.find(a) orelse return;
        const pb = self.find(b) orelse return;
        self.columns[pa.col].windows[pa.row] = b;
        self.columns[pb.col].windows[pb.row] = a;
    }

    /// Swaps the focused column with its neighbour (dx) or the window with the one above/below it (dy).
    pub fn move(self: *ScrollStrip, wid: WindowId, dx: i8, dy: i8) bool {
        const pos = self.find(wid) orelse return false;
        if (dx != 0) {
            const c = @as(i64, @intCast(pos.col)) + dx;
            if (c < 0 or c >= self.count) return false;
            const other: usize = @intCast(c);
            std.mem.swap(Column, &self.columns[pos.col], &self.columns[other]);
            return true;
        }
        const col = &self.columns[pos.col];
        const r = @as(i64, @intCast(pos.row)) + dy;
        if (r < 0 or r >= col.count) return false;
        const other: usize = @intCast(r);
        std.mem.swap(WindowId, &col.windows[pos.row], &col.windows[other]);
        col.active = other;
        return true;
    }

    /// Stacks the window into the neighbouring column, or, if it already shares a column, pulls it out
    /// into a column of its own on that side.
    pub fn consumeOrExpel(self: *ScrollStrip, wid: WindowId, dx: i8) bool {
        const pos = self.find(wid) orelse return false;
        const col = &self.columns[pos.col];

        if (col.count > 1) {
            if (self.count >= MAX_COLUMNS) return false;
            const width = col.width;
            col.removeAt(pos.row);
            const at = if (dx < 0) pos.col else pos.col + 1;
            self.insertColumn(at, wid);
            self.columns[at].width = width;
            return true;
        }

        const c = @as(i64, @intCast(pos.col)) + dx;
        if (c < 0 or c >= self.count) return false;
        const target = &self.columns[@intCast(c)];
        if (target.count >= MAX_COLUMN_WINDOWS) return false;
        target.windows[target.count] = wid;
        target.active = target.count;
        target.count += 1;
        self.removeColumn(pos.col);
        return true;
    }

    /// Steps the column to the next preset width (wrapping around).
    pub fn cycleWidth(self: *ScrollStrip, wid: WindowId) void {
        const pos = self.find(wid) orelse return;
        const col = &self.columns[pos.col];
        for (width_presets) |w| {
            if (w > col.width + 0.01) {
                col.width = w;
                return;
            }
        }
        col.width = width_presets[0];
    }

    pub fn resize(self: *ScrollStrip, wid: WindowId, delta: f64) void {
        const pos = self.find(wid) orelse return;
        const col = &self.columns[pos.col];
        col.width = std.math.clamp(col.width + delta, 0.1, 1.0);
    }

    /// Lays out every column (including those scrolled out of view, which land outside `screen_rect`)
    /// and scrolls just far enough to show the column holding `focused`.
    pub fn layout(
        self: *ScrollStrip,
        screen_rect: Rect,
        gaps: GapConfig,
        mins: *const WindowHints,
        focused: ?WindowId,
        max_count: usize,
        out_ids: [*]WindowId,
        out_rects: [*]Rect,
    ) usize {
        if (self.count == 0 or max_count == 0) return 0;
        const usable = screen_rect.insetUniform(gaps.outer);
        const gap = gaps.inner;

        var xs: [MAX_COLUMNS]f64 = undefined;
        var ws: [MAX_COLUMNS]f64 = undefined;
        var strip_w: f64 = 0;
        for (0..self.count) |c| {
            const col = &self.columns[c];
            var min_w: f64 = 0;
            for (0..col.count) |r| min_w = @max(min_w, mins.get(col.windows[r]).width);
            const w = @round(col.width * (usable.width + gap) - gap);
            ws[c] = @min(usable.width, @max(w, min_w));
            if (c > 0) strip_w += gap;
            xs[c] = strip_w;
            strip_w += ws[c];
        }

        if (strip_w <= usable.width) {
            // Everything fits: centre the strip instead of hugging the left edge.
            self.view_x = -@round((usable.width - strip_w) / 2);
        } else {
            if (focused) |f| {
                if (self.find(f)) |pos| {
                    const left = xs[pos.col];
                    const right = left + ws[pos.col];
                    if (left < self.view_x) self.view_x = left;
                    if (right > self.view_x + usable.width) self.view_x = right - usable.width;
                }
            }
            self.view_x = std.math.clamp(self.view_x, 0, strip_w - usable.width);
        }

        var count: usize = 0;
        for (0..self.count) |c| {
            const col = &self.columns[c];
            var min_hs: [MAX_COLUMN_WINDOWS]f64 = undefined;
            for (0..col.count) |r| min_hs[r] = mins.get(col.windows[r]).height;
            var hs: [MAX_COLUMN_WINDOWS]f64 = undefined;
            _ = constraints.distribute(usable.height, gap, min_hs[0..col.count], hs[0..col.count]);

            var y = usable.y;
            for (0..col.count) |r| {
                if (count >= max_count) return count;
                out_ids[count] = col.windows[r];
                out_rects[count] = .{
                    .x = usable.x + xs[c] - self.view_x,
                    .y = y,
                    .width = ws[c],
                    .height = hs[r],
                };
                y += hs[r] + gap;
                count += 1;
            }
        }
        return count;
    }
};

const test_screen = Rect{ .x = 0, .y = 0, .width = 1000, .height = 600 };
const test_gaps = GapConfig{ .inner = 0, .outer = 0 };

test "ScrollStrip scrolls to the focused column" {
    var strip = ScrollStrip{};
    strip.insertColumn(0, 1);
    strip.insertColumn(1, 2);
    strip.insertColumn(2, 3);

    var ids: [8]WindowId = undefined;
    var rects: [8]Rect = undefined;
    const mins = WindowHints{};

    _ = strip.layout(test_screen, test_gaps, &mins, 1, 8, &ids, &rects);
    try std.testing.expectEqual(@as(f64, 0), rects[0].x);
    try std.testing.expectEqual(@as(f64, 500), rects[0].width);
    try std.testing.expect(rects[2].x >= test_screen.width); // off to the right

    _ = strip.layout(test_screen, test_gaps, &mins, 3, 8, &ids, &rects);
    try std.testing.expectEqual(@as(f64, 500), rects[2].x);
    try std.testing.expect(rects[0].x + rects[0].width <= 0); // scrolled off the left
}

test "ScrollStrip columns honour minimum widths" {
    var strip = ScrollStrip{};
    strip.insertColumn(0, 1);
    var mins = WindowHints{};
    mins.set(1, .{ .width = 700 });

    var ids: [8]WindowId = undefined;
    var rects: [8]Rect = undefined;
    _ = strip.layout(test_screen, test_gaps, &mins, 1, 8, &ids, &rects);
    try std.testing.expectEqual(@as(f64, 700), rects[0].width);
    try std.testing.expectEqual(@as(f64, 150), rects[0].x); // centred
}

test "ScrollStrip consume and expel" {
    var strip = ScrollStrip{};
    strip.insertColumn(0, 1);
    strip.insertColumn(1, 2);

    try std.testing.expect(strip.consumeOrExpel(2, -1));
    try std.testing.expectEqual(@as(usize, 1), strip.count);
    try std.testing.expectEqual(@as(usize, 2), strip.columns[0].count);

    try std.testing.expect(strip.consumeOrExpel(2, 1));
    try std.testing.expectEqual(@as(usize, 2), strip.count);
    try std.testing.expectEqual(@as(?Position, .{ .col = 1, .row = 0 }), strip.find(2));
}

test "ScrollStrip cycles preset widths" {
    var strip = ScrollStrip{};
    strip.insertColumn(0, 1);
    strip.cycleWidth(1);
    try std.testing.expectEqual(width_presets[2], strip.columns[0].width);
    strip.cycleWidth(1);
    try std.testing.expectEqual(width_presets[0], strip.columns[0].width);
}
