const std = @import("std");
const zlua = @import("zlua");
const canvas_mod = @import("canvas.zig");
const terminal_mod = @import("terminal.zig");

const Lua = zlua.Lua;
const Canvas = canvas_mod.Canvas;

pub const LuaBridge = struct {
    allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    io: std.Io,
    lua: *Lua,
    canvas: *Canvas,
    rng: std.Random,
    time: f64 = 0,
    dt: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, temp_allocator: std.mem.Allocator, io: std.Io, lua: *Lua, canvas: *Canvas, rng: std.Random) LuaBridge {
        return .{ .allocator = allocator, .temp_allocator = temp_allocator, .io = io, .lua = lua, .canvas = canvas, .rng = rng };
    }

    pub fn register(self: *LuaBridge) void {
        self.lua.pushLightUserdata(@as(*const anyopaque, @ptrCast(self)));
        self.lua.setGlobal("__loam_bridge");
    }

    pub fn loadBrush(self: *LuaBridge, path: []const u8) !void {
        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        var buffer: [8192]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        var list = std.ArrayList(u8).empty;
        try reader.interface.appendRemainingUnlimited(self.temp_allocator, &list);
        const data = try list.toOwnedSlice(self.temp_allocator);
        defer self.temp_allocator.free(data);

        const source = try self.temp_allocator.allocSentinel(u8, data.len, 0);
        @memcpy(source[0..data.len], data);
        defer self.allocator.free(source);

        const stack_top = self.lua.getTop();
        try self.lua.doString(source);
        const returned = self.lua.getTop() - stack_top;
        if (returned > 0 and self.lua.typeOf(-1) == .table) {
            self.lua.pushValue(-1);
            self.lua.setGlobal("__loam_brush");
            self.lua.pop(returned);
            return;
        }
        if (returned > 0) self.lua.pop(returned);

        if (self.lua.getGlobal("brush") != .table) {
            self.lua.pop(1);
            return error.BrushMustReturnTable;
        }

        self.lua.pushValue(-1);
        self.lua.setGlobal("__loam_brush");
        self.lua.pop(1);
    }

    pub fn paint(self: *LuaBridge, event: terminal_mod.Event, dt: f64, time: f64) !void {
        self.dt = dt;
        self.time = time;

        if (self.lua.getGlobal("__loam_brush") != .table) {
            self.lua.pop(1);
            return error.NoBrushLoaded;
        }
        if (self.lua.getField(-1, "paint") != .function) {
            self.lua.pop(2);
            return error.BrushMissingPaint;
        }

        self.pushContext();
        self.pushEvent(event);
        self.lua.protectedCall(.{ .args = 2, .results = 0 }) catch |err| {
            const msg = self.lua.toString(-1) catch "lua brush failed";
            self.lua.pop(1);
            self.lua.pop(1);
            std.debug.print("loam lua error: {s}\n", .{msg});
            return err;
        };
        self.lua.pop(1);
    }

    pub fn wantsFrames(self: *LuaBridge) bool {
        if (self.canvas.particleCount() > 0) return true;
        if (self.lua.getGlobal("__loam_brush") != .table) {
            self.lua.pop(1);
            return false;
        }
        defer self.lua.pop(1);
        if (self.lua.getField(-1, "animated") == .nil) {
            self.lua.pop(1);
            return false;
        }
        defer self.lua.pop(1);
        return self.lua.toBoolean(-1);
    }

    pub fn preview(self: *LuaBridge, width: usize, height: usize, out: *std.ArrayList(u8)) !bool {
        if (self.lua.getGlobal("__loam_brush") != .table) {
            self.lua.pop(1);
            return error.NoBrushLoaded;
        }
        if (self.lua.getField(-1, "preview") != .function) {
            self.lua.pop(2);
            return false;
        }

        self.pushContext();
        self.lua.pushInteger(@intCast(width));
        self.lua.pushInteger(@intCast(height));
        self.lua.protectedCall(.{ .args = 3, .results = 1 }) catch |err| {
            const msg = self.lua.toString(-1) catch "lua preview failed";
            self.lua.pop(1);
            self.lua.pop(1);
            std.debug.print("loam lua preview error: {s}\n", .{msg});
            return err;
        };

        const text = self.lua.toString(-1) catch "";
        out.clearRetainingCapacity();
        try out.appendSlice(self.allocator, text);
        self.lua.pop(2);
        return true;
    }

    fn pushContext(self: *LuaBridge) void {
        const lua = self.lua;
        lua.newTable();

        inline for (.{
            .{ "set", zlua.wrap(ctxSet) },
            .{ "emit", zlua.wrap(ctxEmit) },
            .{ "spawn", zlua.wrap(ctxEmit) },
            .{ "get", zlua.wrap(ctxGet) },
            .{ "stageSet", zlua.wrap(ctxStageSet) },
            .{ "stageGet", zlua.wrap(ctxStageGet) },
            .{ "stageClear", zlua.wrap(ctxStageClear) },
            .{ "commitStage", zlua.wrap(ctxCommitStage) },
            .{ "clear", zlua.wrap(ctxClear) },
            .{ "size", zlua.wrap(ctxSize) },
            .{ "width", zlua.wrap(ctxWidth) },
            .{ "height", zlua.wrap(ctxHeight) },
            .{ "worldSize", zlua.wrap(ctxWorldSize) },
            .{ "worldWidth", zlua.wrap(ctxWorldWidth) },
            .{ "worldHeight", zlua.wrap(ctxWorldHeight) },
            .{ "particleCount", zlua.wrap(ctxParticleCount) },
            .{ "getParticle", zlua.wrap(ctxGetParticle) },
            .{ "setParticle", zlua.wrap(ctxSetParticle) },
            .{ "removeParticle", zlua.wrap(ctxRemoveParticle) },
            .{ "eachParticle", zlua.wrap(ctxEachParticle) },
            .{ "time", zlua.wrap(ctxTime) },
            .{ "dt", zlua.wrap(ctxDt) },
            .{ "random", zlua.wrap(ctxRandom) },
            .{ "randomRange", zlua.wrap(ctxRandomRange) },
        }) |item| {
            lua.pushFunction(item[1]);
            lua.setField(-2, item[0]);
        }
    }

    fn pushEvent(self: *LuaBridge, event: terminal_mod.Event) void {
        const lua = self.lua;
        lua.newTable();

        switch (event) {
            .key => |key| {
                pushFieldS(lua, -1, "type", "key");
                switch (key) {
                    .digit => |digit| {
                        pushFieldS(lua, -1, "type", "digit");
                        pushFieldI(lua, -1, "digit", digit);
                    },
                    .escape => pushFieldS(lua, -1, "key", "escape"),
                    .q => pushFieldS(lua, -1, "key", "q"),
                    .b => pushFieldS(lua, -1, "key", "b"),
                    .n => pushFieldS(lua, -1, "key", "n"),
                    .c => pushFieldS(lua, -1, "key", "c"),
                    .r => pushFieldS(lua, -1, "key", "r"),
                    .v => pushFieldS(lua, -1, "key", "v"),
                    .space => pushFieldS(lua, -1, "key", "space"),
                    .other => |code| pushFieldI(lua, -1, "code", code),
                }
            },
            .mouse => |m| {
                pushFieldS(lua, -1, "type", "mouse");
                pushFieldS(lua, -1, "button", switch (m.button) {
                    .left => "left",
                    .middle => "middle",
                    .right => "right",
                    .wheel_up => "wheel_up",
                    .wheel_down => "wheel_down",
                    .other => "other",
                });
                pushFieldS(lua, -1, "action", switch (m.action) {
                    .press => "press",
                    .move => "move",
                    .release => "release",
                });
                pushFieldI(lua, -1, "x", m.x + 1);
                pushFieldI(lua, -1, "y", m.y + 1);
                pushFieldI(lua, -1, "world_x", self.canvas.viewportToWorldX(m.x) + 1);
                pushFieldI(lua, -1, "world_y", self.canvas.viewportToWorldY(m.y) + 1);
            },
            .resize => |s| {
                pushFieldS(lua, -1, "type", "resize");
                pushFieldI(lua, -1, "width", s.cols);
                pushFieldI(lua, -1, "height", s.rows);
            },
            .paste => |p| {
                pushFieldS(lua, -1, "type", "paste");
                pushFieldI(lua, -1, "x", self.canvas.viewportToWorldX(p.x) + 1);
                pushFieldI(lua, -1, "y", self.canvas.viewportToWorldY(p.y) + 1);
                pushFieldS(lua, -1, "text", p.text);
                pushFieldI(lua, -1, "positioned", if (p.positioned) @as(i32, 1) else @as(i32, 0));
            },
            .frame => pushFieldS(lua, -1, "type", "frame"),
            .quit => pushFieldS(lua, -1, "type", "quit"),
        }

        pushFieldF(lua, -1, "dt", self.dt);
        pushFieldF(lua, -1, "time", self.time);
    }
};

fn bridgeFromLua(lua: *Lua) *LuaBridge {
    _ = lua.getGlobal("__loam_bridge");
    defer lua.pop(1);
    return lua.toUserdata(LuaBridge, -1) catch @panic("missing loam bridge");
}

fn argInt(lua: *Lua, index: i32, default_value: isize) isize {
    return @intCast(lua.toInteger(index) catch default_value);
}

fn argFloat(lua: *Lua, index: i32, default_value: f64) f64 {
    return @floatCast(lua.toNumber(index) catch default_value);
}

fn argGlyph(lua: *Lua, index: i32) []const u8 {
    const s = lua.toString(index) catch " ";
    return if (s.len == 0) " " else s;
}

fn cellIndex(lua: *Lua, index: i32, default_value: isize) usize {
    const v = argInt(lua, index, default_value);
    return if (v <= 1) 0 else @as(usize, @intCast(v - 1));
}

fn pushFieldI(lua: *Lua, index: i32, key: [:0]const u8, value: anytype) void {
    const table = lua.absIndex(index);
    lua.pushInteger(@intCast(value));
    lua.setField(table, key);
}

fn pushFieldF(lua: *Lua, index: i32, key: [:0]const u8, value: f64) void {
    const table = lua.absIndex(index);
    lua.pushNumber(@floatCast(value));
    lua.setField(table, key);
}

fn pushFieldS(lua: *Lua, index: i32, key: [:0]const u8, value: []const u8) void {
    const table = lua.absIndex(index);
    _ = lua.pushString(value);
    lua.setField(table, key);
}

fn ctxSet(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    const x = cellIndex(lua, 1, 1);
    const y = cellIndex(lua, 2, 1);
    const ok = x < b.canvas.world.width and y < b.canvas.world.height;
    if (ok) b.canvas.set(x, y, argGlyph(lua, 3));
    lua.pushBoolean(ok);
    return 1;
}

fn ctxStageSet(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    const world_x = cellIndex(lua, 1, 1);
    const world_y = cellIndex(lua, 2, 1);
    if (world_x < b.canvas.viewport.x or world_y < b.canvas.viewport.y) {
        lua.pushBoolean(false);
        return 1;
    }

    const x = world_x - b.canvas.viewport.x;
    const y = world_y - b.canvas.viewport.y;
    const ok = x < b.canvas.viewport.width and y < b.canvas.viewport.height;
    if (ok) b.canvas.setStage(x, y, argGlyph(lua, 3));
    lua.pushBoolean(ok);
    return 1;
}

fn ctxStageGet(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    const world_x = cellIndex(lua, 1, 1);
    const world_y = cellIndex(lua, 2, 1);
    if (world_x < b.canvas.viewport.x or world_y < b.canvas.viewport.y) {
        _ = lua.pushString(" ");
        return 1;
    }

    _ = lua.pushString(b.canvas.getStage(world_x - b.canvas.viewport.x, world_y - b.canvas.viewport.y));
    return 1;
}

fn ctxStageClear(lua: *Lua) i32 {
    bridgeFromLua(lua).canvas.clearStage();
    return 0;
}

fn ctxCommitStage(lua: *Lua) i32 {
    bridgeFromLua(lua).canvas.commitStage();
    return 0;
}

fn ctxEmit(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    const x = argFloat(lua, 1, 1) - 1;
    const y = argFloat(lua, 2, 1) - 1;
    const seed = @as(u32, @intCast(@mod(@as(i64, @intFromFloat(x * 97 + y * 7919)), 1_000_003)));

    b.canvas.addParticle(.{
        .x = @floatCast(x),
        .y = @floatCast(y),
        .vx = @floatCast(argFloat(lua, 5, 0)),
        .vy = @floatCast(argFloat(lua, 6, 0)),
        .glyph = canvas_mod.Cell.init(argGlyph(lua, 3)),
        .ttl = @floatCast(argFloat(lua, 4, 1)),
        .seed = seed,
    }) catch lua.raiseErrorStr("emit failed", .{});

    lua.pushBoolean(true);
    return 1;
}

fn ctxGet(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    const x = cellIndex(lua, 1, 1);
    const y = cellIndex(lua, 2, 1);
    _ = lua.pushString(b.canvas.get(x, y));
    return 1;
}

fn ctxClear(lua: *Lua) i32 {
    bridgeFromLua(lua).canvas.clear();
    return 0;
}

fn ctxSize(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    lua.pushInteger(@intCast(b.canvas.viewport.width));
    lua.pushInteger(@intCast(b.canvas.viewport.height));
    return 2;
}

fn ctxWidth(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridgeFromLua(lua).canvas.viewport.width));
    return 1;
}

fn ctxHeight(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridgeFromLua(lua).canvas.viewport.height));
    return 1;
}

fn ctxWorldSize(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    lua.pushInteger(@intCast(b.canvas.world.width));
    lua.pushInteger(@intCast(b.canvas.world.height));
    return 2;
}

fn ctxWorldWidth(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridgeFromLua(lua).canvas.world.width));
    return 1;
}

fn ctxWorldHeight(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridgeFromLua(lua).canvas.world.height));
    return 1;
}

fn ctxParticleCount(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridgeFromLua(lua).canvas.particleCount()));
    return 1;
}

fn ctxGetParticle(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    const i = cellIndex(lua, 1, 1);
    if (i >= b.canvas.world.particles.items.len) {
        lua.pushBoolean(false);
        return 1;
    }

    const p = b.canvas.world.particles.items[i];
    lua.pushBoolean(true);
    lua.pushNumber(p.x);
    lua.pushNumber(p.y);
    lua.pushNumber(p.vx);
    lua.pushNumber(p.vy);
    _ = lua.pushString(p.glyph.slice());
    lua.pushNumber(p.ttl);
    lua.pushNumber(p.age);
    lua.pushInteger(p.seed);
    return 9;
}

fn ctxSetParticle(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    const i = cellIndex(lua, 1, 1);
    if (i >= b.canvas.world.particles.items.len) {
        lua.pushBoolean(false);
        return 1;
    }

    var p = b.canvas.world.particles.items[i];
    p.x = @floatCast(argFloat(lua, 2, p.x));
    p.y = @floatCast(argFloat(lua, 3, p.y));
    p.vx = @floatCast(argFloat(lua, 4, p.vx));
    p.vy = @floatCast(argFloat(lua, 5, p.vy));
    p.glyph = canvas_mod.Cell.init(argGlyph(lua, 6));
    p.ttl = @floatCast(argFloat(lua, 7, p.ttl));
    b.canvas.world.particles.items[i] = p;
    lua.pushBoolean(true);
    return 1;
}

fn ctxRemoveParticle(lua: *Lua) i32 {
    lua.pushBoolean(bridgeFromLua(lua).canvas.removeParticle(cellIndex(lua, 1, 1)));
    return 1;
}

fn ctxEachParticle(lua: *Lua) anyerror!i32 {
    const b = bridgeFromLua(lua);
    if (lua.typeOf(1) != .function) return error.ExpectedFunction;

    var i = b.canvas.world.particles.items.len;
    while (i > 0) {
        i -= 1;
        lua.pushValue(1);
        lua.pushInteger(@intCast(i + 1));
        lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
            _ = lua.toString(-1) catch "particle callback failed";
            lua.pop(1);
            lua.raiseErrorStr("particle callback failed", .{});
        };
    }

    return 0;
}

fn ctxTime(lua: *Lua) i32 {
    lua.pushNumber(bridgeFromLua(lua).time);
    return 1;
}

fn ctxDt(lua: *Lua) i32 {
    lua.pushNumber(bridgeFromLua(lua).dt);
    return 1;
}

fn ctxRandom(lua: *Lua) i32 {
    lua.pushNumber(bridgeFromLua(lua).rng.float(f64));
    return 1;
}

fn ctxRandomRange(lua: *Lua) i32 {
    const b = bridgeFromLua(lua);
    var a = argFloat(lua, 1, 0);
    var c = argFloat(lua, 2, 1);
    if (a > c) std.mem.swap(f64, &a, &c);
    lua.pushNumber(a + (c - a) * b.rng.float(f64));
    return 1;
}
