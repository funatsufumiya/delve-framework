const std = @import("std");
const batcher = @import("../graphics/batcher.zig");
const debug = @import("../debug.zig");
const graphics = @import("../platform/graphics.zig");
const images = @import("../images.zig");
const input = @import("../platform/input.zig");
const math = @import("../math.zig");
const modules = @import("../modules.zig");

pub const test_asset = @embedFile("../static/test.gif");

var time: f32 = 0.0;
var texture: graphics.Texture = undefined;

pub fn registerModule() !void {
    const debugDrawExample = modules.Module {
        .init_fn = on_init,
        .tick_fn = on_tick,
        .draw_fn = on_draw,
        .cleanup_fn = on_cleanup,
    };

    try modules.registerModule(debugDrawExample);
}

fn on_init() void {
    debug.log("Debug draw example module initializing", .{});

    var test_image = images.loadBytes(test_asset) catch {
        debug.log("Could not load test texture", .{});
        return;
    };
    texture = graphics.Texture.init(&test_image);
}

fn on_tick(tick: u64) void {
    time = @floatFromInt(tick);
}

fn on_draw() void {
    graphics.setDebugDrawTexture(texture);
    graphics.drawDebugRectangle(50.0, 50.0, 100.0, 100.0);

    graphics.setDebugTextScale(1.5, 1.5);
    graphics.setDebugTextColor4f(1.0, std.math.sin(time * 0.02), 0.0, 1.0);
    graphics.drawDebugText(2.0, 165.0, "This is from the debug draw module!");
}

fn on_cleanup() void {
    debug.log("Debug draw example module cleaning up", .{});
}
