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

    pub fn eql(a: Cell, b: Cell) bool {
        return a.len == b.len and std.mem.eql(u8, a.slice(), b.slice());
    }
};

fn utf8CellLen(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    const first = bytes[0];
    const wanted: usize = if (first < 0x80) 1 else if (first & 0xe0 == 0xc0) 2 else if (first & 0xf0 == 0xe0) 3 else if (first & 0xf8 == 0xf0) 4 else 1;
    return @min(wanted, bytes.len);
}

pub const Selection = struct {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,

    pub fn left(self: Selection) usize {
        return @min(self.x0, self.x1);
    }

    pub fn right(self: Selection) usize {
        return @max(self.x0, self.x1);
    }

    pub fn top(self: Selection) usize {
        return @min(self.y0, self.y1);
    }

    pub fn bottom(self: Selection) usize {
        return @max(self.y0, self.y1);
    }

    pub fn width(self: Selection) usize {
        return self.right() - self.left() + 1;
    }

    pub fn height(self: Selection) usize {
        return self.bottom() - self.top() + 1;
    }

    pub fn contains(self: Selection, x: usize, y: usize) bool {
        return x >= self.left() and x <= self.right() and y >= self.top() and y <= self.bottom();
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

pub const OverlayCell = struct {
    active: bool = false,
    cell: Cell = Cell.space,
};

pub const Overlay = struct {
    allocator: std.mem.Allocator,
    cells: []OverlayCell,
    width: usize,
    height: usize,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Overlay {
        const w = @max(width, 1);
        const h = @max(height, 1);
        const cells = try allocator.alloc(OverlayCell, w * h);
        @memset(cells, OverlayCell{});
        return .{ .allocator = allocator, .cells = cells, .width = w, .height = h };
    }

    pub fn deinit(self: *Overlay) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn resize(self: *Overlay, width: usize, height: usize) !void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        if (w == self.width and h == self.height) return;
        self.allocator.free(self.cells);
        self.cells = try self.allocator.alloc(OverlayCell, w * h);
        @memset(self.cells, OverlayCell{});
        self.width = w;
        self.height = h;
    }

    pub fn clear(self: *Overlay) void {
        @memset(self.cells, OverlayCell{});
    }

    pub fn set(self: *Overlay, x: usize, y: usize, glyph: []const u8) void {
        if (x >= self.width or y >= self.height) return;
        var c = OverlayCell{ .active = true };
        c.cell.set(glyph);
        self.cells[y * self.width + x] = c;
    }

    pub fn setCell(self: *Overlay, x: usize, y: usize, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x] = .{ .active = true, .cell = cell };
    }

    pub fn text(self: *Overlay, x: usize, y: usize, text_value: []const u8) void {
        var i: usize = 0;
        var col: usize = 0;
        while (i < text_value.len and x + col < self.width) : (col += 1) {
            const n = utf8CellLen(text_value[i..]);
            self.set(x + col, y, text_value[i .. i + n]);
            i += n;
        }
    }

    pub fn get(self: *const Overlay, x: usize, y: usize) ?Cell {
        if (x >= self.width or y >= self.height) return null;
        const c = self.cells[y * self.width + x];
        return if (c.active) c.cell else null;
    }
};

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    width: usize,
    height: usize,
    viewport_x: usize = 0,
    viewport_y: usize = 0,
    viewport_width: usize,
    viewport_height: usize,
    particles: std.ArrayList(Particle) = .empty,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Canvas {
        const w = @max(width, 1);
        const h = @max(height, 1);
        const cells = try allocator.alloc(Cell, w * h);
        @memset(cells, Cell.space);
        return .{ .allocator = allocator, .cells = cells, .width = w, .height = h, .viewport_width = w, .viewport_height = h };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.cells);
        self.particles.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn resize(self: *Canvas, width: usize, height: usize) !void {
        self.viewport_width = @max(width, 1);
        self.viewport_height = @max(height, 1);
        try self.growTo(self.viewport_x + self.viewport_width, self.viewport_y + self.viewport_height);
        self.clampViewport();
    }

    fn growTo(self: *Canvas, width: usize, height: usize) !void {
        if (width <= self.width and height <= self.height) return;
        const next_w = @max(width, self.width);
        const next_h = @max(height, self.height);
        const next = try self.allocator.alloc(Cell, next_w * next_h);
        @memset(next, Cell.space);
        var y: usize = 0;
        while (y < self.height) : (y += 1) @memcpy(next[y * next_w .. y * next_w + self.width], self.cells[y * self.width .. y * self.width + self.width]);
        self.allocator.free(self.cells);
        self.cells = next;
        self.width = next_w;
        self.height = next_h;
    }

    fn clampViewport(self: *Canvas) void {
        self.viewport_x = @min(self.viewport_x, if (self.width <= self.viewport_width) 0 else self.width - self.viewport_width);
        self.viewport_y = @min(self.viewport_y, if (self.height <= self.viewport_height) 0 else self.height - self.viewport_height);
    }

    pub fn clear(self: *Canvas) void {
        @memset(self.cells, Cell.space);
        self.particles.clearRetainingCapacity();
    }

    pub fn set(self: *Canvas, x: usize, y: usize, glyph: []const u8) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x].set(glyph);
    }

    pub fn setCell(self: *Canvas, x: usize, y: usize, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x] = cell;
    }

    pub fn get(self: *const Canvas, x: usize, y: usize) []const u8 {
        if (x >= self.width or y >= self.height) return Cell.space.slice();
        return self.cells[y * self.width + x].slice();
    }

    pub fn getCell(self: *const Canvas, x: usize, y: usize) Cell {
        if (x >= self.width or y >= self.height) return Cell.space;
        return self.cells[y * self.width + x];
    }

    pub fn cellAtViewport(self: *const Canvas, x: usize, y: usize) Cell {
        return self.getCell(self.viewport_x + x, self.viewport_y + y);
    }

    pub fn viewportToWorldX(self: *const Canvas, x: usize) usize {
        return @min(self.viewport_x + x, self.width -| 1);
    }

    pub fn viewportToWorldY(self: *const Canvas, y: usize) usize {
        return @min(self.viewport_y + y, self.height -| 1);
    }

    pub fn addParticle(self: *Canvas, p: Particle) !void {
        try self.particles.append(self.allocator, p);
    }

    pub fn removeParticle(self: *Canvas, index: usize) bool {
        if (index >= self.particles.items.len) return false;
        _ = self.particles.swapRemove(index);
        return true;
    }

    pub fn particleCount(self: *const Canvas) usize {
        return self.particles.items.len;
    }
};

test "overlay text keeps utf8 glyph bytes per cell" {
    var overlay = try Overlay.init(std.testing.allocator, 4, 1);
    defer overlay.deinit();

    overlay.text(0, 0, "┌─a");
    try std.testing.expectEqualStrings("┌", overlay.get(0, 0).?.slice());
    try std.testing.expectEqualStrings("─", overlay.get(1, 0).?.slice());
    try std.testing.expectEqualStrings("a", overlay.get(2, 0).?.slice());
}
