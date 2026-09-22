pub const geometry = @import("geometry.zig");
pub const bsp = @import("bsp.zig");
pub const tiling = @import("tiling.zig");
pub const workspace = @import("workspace.zig");

comptime {
    _ = tiling;
    _ = bsp;
    _ = geometry;
    _ = workspace;
}

test {
    _ = @import("geometry.zig");
    _ = @import("bsp.zig");
    _ = @import("tiling.zig");
    _ = @import("workspace.zig");
}
