const std = @import("std");

pub const max_glyph_bytes = 8;

pub const Cell = struct {
    bytes: [max_glyph_bytes]u8 = space.bytes,
    len: u8 = 1,

    pub const space = Cell{ .bytes = .{ ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ' }, .len = 1 };

    pub fn init(text: []const u8) Cell {
        var cell = space;
        cell.set(text);
        return cell;
    }

    pub fn set(self: *Cell, text: []const u8) void {
        const n = @min(text.len, max_glyph_bytes);
        @memcpy(self.bytes[0..n], text[0..n]);
        if (n < max_glyph_bytes) @memset(self.bytes[n..], ' ');
        self.len = @intCast(n);
    }

    pub fn slice(self: *const Cell) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Particle = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    glyph: Cell,
    ttl: f32,
    age: f32 = 0,
    seed: u32 = 0,
};

pub const Selection = struct {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,

    pub fn contains(self: Selection, x: usize, y: usize) bool {
        const lx = @min(self.x0, self.x1);
        const rx = @max(self.x0, self.x1);
        const ty = @min(self.y0, self.y1);
        const by = @max(self.y0, self.y1);
        return x >= lx and x <= rx and y >= ty and y <= by;
    }
};

const World = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    particles: std.ArrayList(Particle) = .empty,
    width: usize,
    height: usize,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize) !World {
        const cells = try allocator.alloc(Cell, width * height);
        @memset(cells, Cell.space);
        return .{ .allocator = allocator, .cells = cells, .width = width, .height = height };
    }

    fn deinit(self: *World) void {
        self.allocator.free(self.cells);
        self.particles.deinit(self.allocator);
        self.* = undefined;
    }

    fn clear(self: *World) void {
        @memset(self.cells, Cell.space);
        self.particles.clearRetainingCapacity();
    }

    fn growTo(self: *World, width: usize, height: usize) !void {
        if (width <= self.width and height <= self.height) return;

        const next_width = @max(width, self.width);
        const next_height = @max(height, self.height);
        const next = try self.allocator.alloc(Cell, next_width * next_height);
        @memset(next, Cell.space);

        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            @memcpy(next[y * next_width .. y * next_width + self.width], self.cells[y * self.width .. y * self.width + self.width]);
        }

        self.allocator.free(self.cells);
        self.cells = next;
        self.width = next_width;
        self.height = next_height;
    }

    fn set(self: *World, x: usize, y: usize, glyph: []const u8) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x].set(glyph);
    }

    fn get(self: *const World, x: usize, y: usize) []const u8 {
        if (x >= self.width or y >= self.height) return Cell.space.slice();
        return self.cells[y * self.width + x].slice();
    }

    fn addParticle(self: *World, allocator: std.mem.Allocator, p: Particle) !void {
        try self.particles.append(allocator, p);
    }

    fn removeParticle(self: *World, index: usize) bool {
        if (index >= self.particles.items.len) return false;
        _ = self.particles.swapRemove(index);
        return true;
    }
};

const Viewport = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize,
    height: usize,

    fn clampToWorld(self: *Viewport, world_width: usize, world_height: usize) void {
        if (world_width == 0 or world_height == 0) return;
        self.width = @max(self.width, 1);
        self.height = @max(self.height, 1);
        const max_x = if (world_width <= self.width) 0 else world_width - self.width;
        const max_y = if (world_height <= self.height) 0 else world_height - self.height;
        self.x = @min(self.x, max_x);
        self.y = @min(self.y, max_y);
    }
};

const StageCell = struct {
    cell: Cell = Cell.space,
    active: bool = false,
};

const Stage = struct {
    allocator: std.mem.Allocator,
    cells: []StageCell,
    width: usize,
    height: usize,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Stage {
        const cells = try allocator.alloc(StageCell, width * height);
        @memset(cells, StageCell{});
        return .{ .allocator = allocator, .cells = cells, .width = width, .height = height };
    }

    fn deinit(self: *Stage) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    fn resize(self: *Stage, width: usize, height: usize) !void {
        if (width == self.width and height == self.height) return;

        var next = try self.allocator.alloc(StageCell, width * height);
        @memset(next, StageCell{});

        const copy_w = @min(self.width, width);
        const copy_h = @min(self.height, height);
        var y: usize = 0;
        while (y < copy_h) : (y += 1) {
            @memcpy(next[y * width .. y * width + copy_w], self.cells[y * self.width .. y * self.width + copy_w]);
        }

        self.allocator.free(self.cells);
        self.cells = next;
        self.width = width;
        self.height = height;
    }

    fn clear(self: *Stage) void {
        @memset(self.cells, StageCell{});
    }

    fn set(self: *Stage, x: usize, y: usize, glyph: []const u8) void {
        if (x >= self.width or y >= self.height) return;
        var cell = StageCell{};
        cell.cell.set(glyph);
        cell.active = true;
        self.cells[y * self.width + x] = cell;
    }

    fn get(self: *const Stage, x: usize, y: usize) []const u8 {
        if (x >= self.width or y >= self.height) return Cell.space.slice();
        const cell = &self.cells[y * self.width + x];
        return if (cell.active) cell.cell.slice() else Cell.space.slice();
    }

    fn commit(self: *const Stage, world: *World, origin_x: usize, origin_y: usize) void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const cell = &self.cells[y * self.width + x];
                if (cell.active) world.set(origin_x + x, origin_y + y, cell.cell.slice());
            }
        }
    }
};

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    world: World,
    viewport: Viewport,
    stage: Stage,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Canvas {
        return .{
            .allocator = allocator,
            .world = try World.init(allocator, width, height),
            .viewport = .{ .width = width, .height = height },
            .stage = try Stage.init(allocator, width, height),
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.world.deinit();
        self.stage.deinit();
        self.* = undefined;
    }

    pub fn resize(self: *Canvas, width: usize, height: usize) !void {
        self.viewport.width = @max(width, 1);
        self.viewport.height = @max(height, 1);
        try self.world.growTo(self.viewport.x + self.viewport.width, self.viewport.y + self.viewport.height);
        self.viewport.clampToWorld(self.world.width, self.world.height);
        try self.stage.resize(self.viewport.width, self.viewport.height);
    }

    pub fn clear(self: *Canvas) void {
        self.world.clear();
        self.stage.clear();
    }

    pub fn set(self: *Canvas, x: usize, y: usize, glyph: []const u8) void {
        self.world.set(x, y, glyph);
    }

    pub fn setCell(self: *Canvas, x: usize, y: usize, cell: Cell) void {
        if (x >= self.world.width or y >= self.world.height) return;
        self.world.cells[y * self.world.width + x] = cell;
    }

    pub fn get(self: *const Canvas, x: usize, y: usize) []const u8 {
        return self.world.get(x, y);
    }

    pub fn getCell(self: *const Canvas, x: usize, y: usize) Cell {
        if (x >= self.world.width or y >= self.world.height) return Cell.space;
        return self.world.cells[y * self.world.width + x];
    }

    pub fn setStage(self: *Canvas, x: usize, y: usize, glyph: []const u8) void {
        self.stage.set(x, y, glyph);
    }

    pub fn setStageCell(self: *Canvas, x: usize, y: usize, cell: Cell) void {
        self.stage.set(x, y, cell.slice());
    }

    pub fn getStage(self: *const Canvas, x: usize, y: usize) []const u8 {
        return self.stage.get(x, y);
    }

    pub fn clearStage(self: *Canvas) void {
        self.stage.clear();
    }

    pub fn commitStage(self: *Canvas) void {
        self.stage.commit(&self.world, self.viewport.x, self.viewport.y);
        self.stage.clear();
    }

    pub fn addParticle(self: *Canvas, p: Particle) !void {
        try self.world.addParticle(self.allocator, p);
    }

    pub fn removeParticle(self: *Canvas, index: usize) bool {
        return self.world.removeParticle(index);
    }

    pub fn particleCount(self: *const Canvas) usize {
        return self.world.particles.items.len;
    }

    pub fn viewportToWorldX(self: *const Canvas, x: usize) usize {
        return @min(self.viewport.x + x, self.world.width -| 1);
    }

    pub fn viewportToWorldY(self: *const Canvas, y: usize) usize {
        return @min(self.viewport.y + y, self.world.height -| 1);
    }

    pub fn cellAtViewport(self: *const Canvas, x: usize, y: usize) []const u8 {
        if (x >= self.viewport.width or y >= self.viewport.height) return Cell.space.slice();
        const sx = self.viewport.x + x;
        const sy = self.viewport.y + y;
        if (sx >= self.world.width or sy >= self.world.height) return Cell.space.slice();

        const stage_x = x;
        const stage_y = y;
        if (stage_x < self.stage.width and stage_y < self.stage.height) {
            const cell = &self.stage.cells[stage_y * self.stage.width + stage_x];
            if (cell.active) return cell.cell.slice();
        }

        return self.world.get(sx, sy);
    }

    pub fn render(self: *const Canvas, writer: *std.Io.Writer, selection: ?Selection) !void {
        try writer.writeAll("\x1b[?25l\x1b[H\x1b[2J");

        var y: usize = 0;
        while (y < self.viewport.height) : (y += 1) {
            try writer.print("\x1b[{d};1H", .{y + 1});
            var in_selection = false;
            var x: usize = 0;
            while (x < self.viewport.width) : (x += 1) {
                const world_x = self.viewport.x + x;
                const world_y = self.viewport.y + y;
                const selected = if (selection) |s| s.contains(world_x, world_y) else false;
                if (selected != in_selection) {
                    try writer.writeAll(if (selected) "\x1b[7m" else "\x1b[27m");
                    in_selection = selected;
                }
                try writer.writeAll(self.cellAtViewport(x, y));
            }
            if (in_selection) try writer.writeAll("\x1b[27m");
        }

        try writer.writeAll("\x1b[0m");
        try self.renderParticles(writer);
    }

    fn renderParticles(self: *const Canvas, writer: *std.Io.Writer) !void {
        for (self.world.particles.items) |p| {
            const px: isize = @intFromFloat(@round(p.x));
            const py: isize = @intFromFloat(@round(p.y));
            const sx = px - @as(isize, @intCast(self.viewport.x));
            const sy = py - @as(isize, @intCast(self.viewport.y));
            if (sx < 0 or sy < 0) continue;
            if (sx >= @as(isize, @intCast(self.viewport.width))) continue;
            if (sy >= @as(isize, @intCast(self.viewport.height))) continue;

            try writer.print("\x1b[{d};{d}H{s}", .{ @as(usize, @intCast(sy + 1)), @as(usize, @intCast(sx + 1)), p.glyph.slice() });
        }

        try writer.writeAll("\x1b[H");
    }
};
