const std = @import("std");
const zlua = @import("zlua");
const canvas_mod = @import("canvas.zig");
const terminal_mod = @import("terminal.zig");

const Lua = zlua.Lua;
const Canvas = canvas_mod.Canvas;
const Cell = canvas_mod.Cell;
const Overlay = canvas_mod.Overlay;

pub const LuaBridge = struct {
    allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    io: std.Io,
    lua: *Lua,
    canvas: *Canvas,
    overlay: Overlay,
    preview: Overlay,
    rng: std.Random,
    time: f64 = 0,
    dt: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, temp_allocator: std.mem.Allocator, io: std.Io, lua: *Lua, canvas: *Canvas, rng: std.Random, width: usize, height: usize) !LuaBridge {
        return .{
            .allocator = allocator,
            .temp_allocator = temp_allocator,
            .io = io,
            .lua = lua,
            .canvas = canvas,
            .overlay = try Overlay.init(allocator, width, height),
            .preview = try Overlay.init(allocator, 24, 5),
            .rng = rng,
        };
    }

    pub fn deinit(self: *LuaBridge) void {
        self.overlay.deinit();
        self.preview.deinit();
    }

    pub fn resize(self: *LuaBridge, width: usize, height: usize) !void {
        try self.overlay.resize(width, height);
        self.overlay.clear();
    }

    pub fn register(self: *LuaBridge) void {
        self.lua.pushLightUserdata(@as(*const anyopaque, @ptrCast(self)));
        self.lua.setGlobal("__loam_bridge");
    }

    pub fn loadBrush(self: *LuaBridge, path: []const u8) !void {
        self.overlay.clear();
        self.preview.clear();
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
        defer self.temp_allocator.free(source);

        const stack_top = self.lua.getTop();
        try self.lua.doString(source);
        const returned = self.lua.getTop() - stack_top;
        if (returned > 0 and self.lua.typeOf(-1) == .table) {
            self.lua.pushValue(-1);
            self.lua.setGlobal("__loam_brush");
            self.lua.pop(returned);
        } else {
            if (returned > 0) self.lua.pop(returned);
            if (self.lua.getGlobal("brush") != .table) {
                self.lua.pop(1);
                return error.BrushMustReturnTable;
            }
            self.lua.pushValue(-1);
            self.lua.setGlobal("__loam_brush");
            self.lua.pop(1);
        }
        try self.rebuildPreview();
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
        try self.rebuildPreview();
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

    fn rebuildPreview(self: *LuaBridge) !void {
        self.preview.clear();
        if (self.lua.getGlobal("__loam_brush") != .table) {
            self.lua.pop(1);
            return;
        }
        if (self.lua.getField(-1, "preview") != .function) {
            self.lua.pop(2);
            return;
        }
        self.pushContext();
        self.lua.pushInteger(@intCast(self.preview.width));
        self.lua.pushInteger(@intCast(self.preview.height));
        self.lua.protectedCall(.{ .args = 3, .results = 1 }) catch |err| {
            const msg = self.lua.toString(-1) catch "lua preview failed";
            self.lua.pop(1);
            self.lua.pop(1);
            std.debug.print("loam lua preview error: {s}\n", .{msg});
            return err;
        };
        const text = self.lua.toString(-1) catch "";
        var rows = std.mem.splitScalar(u8, text, '\n');
        var y: usize = 0;
        while (y < self.preview.height) : (y += 1) {
            const row = rows.next() orelse "";
            self.preview.text(0, y, row[0..@min(row.len, self.preview.width)]);
        }
        self.lua.pop(2);
    }

    fn pushContext(self: *LuaBridge) void {
        const lua = self.lua;
        lua.newTable();
        inline for (.{
            .{ "set", zlua.wrap(ctxSet) },
            .{ "get", zlua.wrap(ctxGet) },
            .{ "line", zlua.wrap(ctxLine) },
            .{ "fill", zlua.wrap(ctxFill) },
            .{ "rect", zlua.wrap(ctxRect) },
            .{ "overlaySet", zlua.wrap(ctxOverlaySet) },
            .{ "overlayClear", zlua.wrap(ctxOverlayClear) },
            .{ "stageSet", zlua.wrap(ctxOverlaySet) },
            .{ "stageClear", zlua.wrap(ctxOverlayClear) },
            .{ "commitStage", zlua.wrap(ctxCommitOverlay) },
            .{ "clear", zlua.wrap(ctxClear) },
            .{ "emit", zlua.wrap(ctxEmit) },
            .{ "spawn", zlua.wrap(ctxEmit) },
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
            },
            .frame => pushFieldS(lua, -1, "type", "frame"),
            .quit => pushFieldS(lua, -1, "type", "quit"),
        }
        pushFieldF(lua, -1, "dt", self.dt);
        pushFieldF(lua, -1, "time", self.time);
    }
};

fn bridge(lua: *Lua) *LuaBridge {
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
    return if (v <= 1) 0 else @intCast(v - 1);
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
    bridge(lua).canvas.set(cellIndex(lua, 1, 1), cellIndex(lua, 2, 1), argGlyph(lua, 3));
    lua.pushBoolean(true);
    return 1;
}

fn ctxGet(lua: *Lua) i32 {
    _ = lua.pushString(bridge(lua).canvas.get(cellIndex(lua, 1, 1), cellIndex(lua, 2, 1)));
    return 1;
}

fn ctxLine(lua: *Lua) i32 {
    const b = bridge(lua);
    var x0 = argInt(lua, 1, 1) - 1;
    var y0 = argInt(lua, 2, 1) - 1;
    const x1 = argInt(lua, 3, 1) - 1;
    const y1 = argInt(lua, 4, 1) - 1;
    const glyph = argGlyph(lua, 5);
    const dx: isize = @intCast(@abs(x1 - x0));
    const sx: isize = if (x0 < x1) 1 else -1;
    const dy: isize = -@as(isize, @intCast(@abs(y1 - y0)));
    const sy: isize = if (y0 < y1) 1 else -1;
    var err: isize = dx + dy;
    while (true) {
        if (x0 >= 0 and y0 >= 0) b.canvas.set(@intCast(x0), @intCast(y0), glyph);
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
    return 0;
}

fn ctxFill(lua: *Lua) i32 {
    const b = bridge(lua);
    const x = cellIndex(lua, 1, 1);
    const y = cellIndex(lua, 2, 1);
    const w: usize = @intCast(@max(argInt(lua, 3, 1), 1));
    const h: usize = @intCast(@max(argInt(lua, 4, 1), 1));
    const glyph = argGlyph(lua, 5);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        var col: usize = 0;
        while (col < w) : (col += 1) b.canvas.set(x + col, y + row, glyph);
    }
    return 0;
}

fn ctxRect(lua: *Lua) i32 {
    const b = bridge(lua);
    const x = cellIndex(lua, 1, 1);
    const y = cellIndex(lua, 2, 1);
    const w: usize = @intCast(@max(argInt(lua, 3, 1), 1));
    const h: usize = @intCast(@max(argInt(lua, 4, 1), 1));
    const edge = argGlyph(lua, 5);
    const fill = if (lua.typeOf(6) == .nil) null else argGlyph(lua, 6);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        var col: usize = 0;
        while (col < w) : (col += 1) {
            const border = row == 0 or col == 0 or row + 1 == h or col + 1 == w;
            if (border) b.canvas.set(x + col, y + row, edge) else if (fill) |f| b.canvas.set(x + col, y + row, f);
        }
    }
    return 0;
}

fn ctxOverlaySet(lua: *Lua) i32 {
    const b = bridge(lua);
    const wx = cellIndex(lua, 1, 1);
    const wy = cellIndex(lua, 2, 1);
    if (wx >= b.canvas.viewport_x and wy >= b.canvas.viewport_y) b.overlay.set(wx - b.canvas.viewport_x, wy - b.canvas.viewport_y, argGlyph(lua, 3));
    return 0;
}

fn ctxOverlayClear(lua: *Lua) i32 {
    bridge(lua).overlay.clear();
    return 0;
}

fn ctxCommitOverlay(lua: *Lua) i32 {
    const b = bridge(lua);
    var y: usize = 0;
    while (y < b.overlay.height) : (y += 1) {
        var x: usize = 0;
        while (x < b.overlay.width) : (x += 1) if (b.overlay.get(x, y)) |cell| b.canvas.setCell(b.canvas.viewport_x + x, b.canvas.viewport_y + y, cell);
    }
    b.overlay.clear();
    return 0;
}

fn ctxClear(lua: *Lua) i32 {
    bridge(lua).canvas.clear();
    return 0;
}
fn ctxSize(lua: *Lua) i32 {
    const b = bridge(lua);
    lua.pushInteger(@intCast(b.canvas.viewport_width));
    lua.pushInteger(@intCast(b.canvas.viewport_height));
    return 2;
}
fn ctxWidth(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridge(lua).canvas.viewport_width));
    return 1;
}
fn ctxHeight(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridge(lua).canvas.viewport_height));
    return 1;
}
fn ctxWorldSize(lua: *Lua) i32 {
    const b = bridge(lua);
    lua.pushInteger(@intCast(b.canvas.width));
    lua.pushInteger(@intCast(b.canvas.height));
    return 2;
}
fn ctxWorldWidth(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridge(lua).canvas.width));
    return 1;
}
fn ctxWorldHeight(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridge(lua).canvas.height));
    return 1;
}
fn ctxParticleCount(lua: *Lua) i32 {
    lua.pushInteger(@intCast(bridge(lua).canvas.particleCount()));
    return 1;
}

fn ctxEmit(lua: *Lua) i32 {
    const b = bridge(lua);
    const x = argFloat(lua, 1, 1) - 1;
    const y = argFloat(lua, 2, 1) - 1;
    b.canvas.addParticle(.{ .x = @floatCast(x), .y = @floatCast(y), .vx = @floatCast(argFloat(lua, 5, 0)), .vy = @floatCast(argFloat(lua, 6, 0)), .glyph = Cell.init(argGlyph(lua, 3)), .ttl = @floatCast(argFloat(lua, 4, 1)) }) catch lua.raiseErrorStr("emit failed", .{});
    return 0;
}

fn ctxGetParticle(lua: *Lua) i32 {
    const b = bridge(lua);
    const i = cellIndex(lua, 1, 1);
    if (i >= b.canvas.particles.items.len) {
        lua.pushBoolean(false);
        return 1;
    }
    const p = b.canvas.particles.items[i];
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
    const b = bridge(lua);
    const i = cellIndex(lua, 1, 1);
    if (i >= b.canvas.particles.items.len) {
        lua.pushBoolean(false);
        return 1;
    }
    var p = b.canvas.particles.items[i];
    p.x = @floatCast(argFloat(lua, 2, p.x));
    p.y = @floatCast(argFloat(lua, 3, p.y));
    p.vx = @floatCast(argFloat(lua, 4, p.vx));
    p.vy = @floatCast(argFloat(lua, 5, p.vy));
    p.glyph = Cell.init(argGlyph(lua, 6));
    p.ttl = @floatCast(argFloat(lua, 7, p.ttl));
    b.canvas.particles.items[i] = p;
    lua.pushBoolean(true);
    return 1;
}

fn ctxRemoveParticle(lua: *Lua) i32 {
    lua.pushBoolean(bridge(lua).canvas.removeParticle(cellIndex(lua, 1, 1)));
    return 1;
}

fn ctxEachParticle(lua: *Lua) anyerror!i32 {
    const b = bridge(lua);
    if (lua.typeOf(1) != .function) return error.ExpectedFunction;
    var i = b.canvas.particles.items.len;
    while (i > 0) {
        i -= 1;
        lua.pushValue(1);
        lua.pushInteger(@intCast(i + 1));
        lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
            lua.pop(1);
            lua.raiseErrorStr("particle callback failed", .{});
        };
    }
    return 0;
}

fn ctxTime(lua: *Lua) i32 {
    lua.pushNumber(bridge(lua).time);
    return 1;
}
fn ctxDt(lua: *Lua) i32 {
    lua.pushNumber(bridge(lua).dt);
    return 1;
}
fn ctxRandom(lua: *Lua) i32 {
    lua.pushNumber(bridge(lua).rng.float(f64));
    return 1;
}
fn ctxRandomRange(lua: *Lua) i32 {
    const b = bridge(lua);
    var a = argFloat(lua, 1, 0);
    var c = argFloat(lua, 2, 1);
    if (a > c) std.mem.swap(f64, &a, &c);
    lua.pushNumber(a + (c - a) * b.rng.float(f64));
    return 1;
}
