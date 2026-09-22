const std = @import("std");

pub const Rect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn inset(self: Rect, left: f64, right: f64, top: f64, bottom: f64) Rect {
        const new_width = @max(0.0, self.width - left - right);
        const new_height = @max(0.0, self.height - top - bottom);
        return .{
            .x = self.x + left,
            .y = self.y + top,
            .width = new_width,
            .height = new_height,
        };
    }

    pub fn insetUniform(self: Rect, amount: f64) Rect {
        return self.inset(amount, amount, amount, amount);
    }

    pub fn centerX(self: Rect) f64 {
        return self.x + self.width / 2.0;
    }

    pub fn centerY(self: Rect) f64 {
        return self.y + self.height / 2.0;
    }
};

pub const GapConfig = extern struct {
    inner: f64 = 8.0,
    outer: f64 = 10.0,
};

test "Rect geometry and insets" {
    const r = Rect{ .x = 0, .y = 0, .width = 100, .height = 50 };
    const insetValue = r.insetUniform(10);
    try std.testing.expectEqual(@as(f64, 10), insetValue.x);
    try std.testing.expectEqual(@as(f64, 10), insetValue.y);
    try std.testing.expectEqual(@as(f64, 80), insetValue.width);
    try std.testing.expectEqual(@as(f64, 30), insetValue.height);
    try std.testing.expectEqual(@as(f64, 50), r.centerX());
    try std.testing.expectEqual(@as(f64, 25), r.centerY());
}
