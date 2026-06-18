const std = @import("std");
const canvas_mod = @import("canvas.zig");

const Canvas = canvas_mod.Canvas;
const Cell = canvas_mod.Cell;
const Overlay = canvas_mod.Overlay;
const Selection = canvas_mod.Selection;

const DisplayCell = struct {
    cell: Cell = Cell.space,
    reverse: bool = false,

    fn eql(a: DisplayCell, b: DisplayCell) bool {
        return a.reverse == b.reverse and Cell.eql(a.cell, b.cell);
    }
};

pub const MoveOverlay = struct {
    source: Selection,
    left: isize,
    top: isize,
    cells: []const Cell,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    prev: []DisplayCell,
    next: []DisplayCell,
    full: bool = true,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Renderer {
        const w = @max(width, 1);
        const h = @max(height, 1);
        const prev = try allocator.alloc(DisplayCell, w * h);
        errdefer allocator.free(prev);
        const next = try allocator.alloc(DisplayCell, w * h);
        @memset(prev, DisplayCell{});
        @memset(next, DisplayCell{});
        return .{ .allocator = allocator, .width = w, .height = h, .prev = prev, .next = next };
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.prev);
        self.allocator.free(self.next);
        self.* = undefined;
    }

    pub fn resize(self: *Renderer, width: usize, height: usize) !void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        if (w == self.width and h == self.height) return;
        self.allocator.free(self.prev);
        self.allocator.free(self.next);
        self.prev = try self.allocator.alloc(DisplayCell, w * h);
        errdefer self.allocator.free(self.prev);
        self.next = try self.allocator.alloc(DisplayCell, w * h);
        @memset(self.prev, DisplayCell{});
        @memset(self.next, DisplayCell{});
        self.width = w;
        self.height = h;
        self.full = true;
    }

    pub fn render(self: *Renderer, writer: *std.Io.Writer, canvas: *const Canvas, brush_overlay: *const Overlay, preview: *const Overlay, selection: ?Selection, move: ?MoveOverlay, countdown: ?usize) !void {
        self.compose(canvas, brush_overlay, preview, selection, move, countdown);
        if (self.full) {
            try writer.writeAll("\x1b[2J");
            @memset(self.prev, DisplayCell{});
            self.full = false;
        }
        try self.flush(writer);
    }

    fn compose(self: *Renderer, canvas: *const Canvas, brush_overlay: *const Overlay, preview: *const Overlay, selection: ?Selection, move: ?MoveOverlay, countdown: ?usize) void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) self.put(x, y, canvas.cellAtViewport(x, y), false);
        }
        self.applyParticles(canvas);
        self.applyBrushOverlay(brush_overlay);
        if (move) |m| self.applyMove(canvas, m);
        self.applyPreview(preview);
        self.applyCountdown(countdown);
        self.applySelection(canvas, if (move) |m| moveSelection(m) else selection);
    }

    fn put(self: *Renderer, x: usize, y: usize, cell: Cell, reverse: bool) void {
        if (x >= self.width or y >= self.height) return;
        self.next[y * self.width + x] = .{ .cell = cell, .reverse = reverse };
    }

    fn putWorld(self: *Renderer, canvas: *const Canvas, x: usize, y: usize, cell: Cell, reverse: bool) void {
        if (x < canvas.viewport_x or y < canvas.viewport_y) return;
        self.put(x - canvas.viewport_x, y - canvas.viewport_y, cell, reverse);
    }

    fn applyParticles(self: *Renderer, canvas: *const Canvas) void {
        for (canvas.particles.items) |p| {
            const sx = @as(isize, @intFromFloat(@round(p.x))) - @as(isize, @intCast(canvas.viewport_x));
            const sy = @as(isize, @intFromFloat(@round(p.y))) - @as(isize, @intCast(canvas.viewport_y));
            if (sx >= 0 and sy >= 0) self.put(@intCast(sx), @intCast(sy), p.glyph, false);
        }
    }

    fn applyBrushOverlay(self: *Renderer, overlay: *const Overlay) void {
        const h = @min(self.height, overlay.height);
        const w = @min(self.width, overlay.width);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            var x: usize = 0;
            while (x < w) : (x += 1) if (overlay.get(x, y)) |cell| self.put(x, y, cell, false);
        }
    }

    fn applyMove(self: *Renderer, canvas: *const Canvas, move: MoveOverlay) void {
        const w = move.source.width();
        const h = move.source.height();
        var y: usize = 0;
        while (y < h) : (y += 1) {
            var x: usize = 0;
            while (x < w) : (x += 1) self.putWorld(canvas, move.source.left() + x, move.source.top() + y, Cell.space, false);
        }
        y = 0;
        while (y < h) : (y += 1) {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const wx = move.left + @as(isize, @intCast(x));
                const wy = move.top + @as(isize, @intCast(y));
                if (wx >= 0 and wy >= 0) self.putWorld(canvas, @intCast(wx), @intCast(wy), move.cells[y * w + x], false);
            }
        }
    }

    fn applyPreview(self: *Renderer, preview: *const Overlay) void {
        if (self.width < preview.width + 2 or self.height < preview.height + 2) return;
        const left = self.width - preview.width - 1;
        const top: usize = 1;
        var y: usize = 0;
        while (y < preview.height) : (y += 1) {
            var x: usize = 0;
            while (x < preview.width) : (x += 1) self.put(left + x, top + y, preview.get(x, y) orelse Cell.space, false);
        }
    }

    fn applyCountdown(self: *Renderer, n: ?usize) void {
        const value = n orelse return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " escape clear {d} ", .{value}) catch return;
        var x: usize = 0;
        while (x < text.len and x < self.width) : (x += 1) self.put(x, 0, Cell.init(text[x .. x + 1]), true);
    }

    fn applySelection(self: *Renderer, canvas: *const Canvas, selection: ?Selection) void {
        const s = selection orelse return;
        const left = @max(s.left(), canvas.viewport_x);
        const top = @max(s.top(), canvas.viewport_y);
        const right = @min(s.right(), canvas.viewport_x + self.width -| 1);
        const bottom = @min(s.bottom(), canvas.viewport_y + self.height -| 1);
        if (left > right or top > bottom) return;
        var y = top;
        while (y <= bottom) : (y += 1) {
            var x = left;
            while (x <= right) : (x += 1) self.next[(y - canvas.viewport_y) * self.width + (x - canvas.viewport_x)].reverse = true;
        }
    }

    fn flush(self: *Renderer, writer: *std.Io.Writer) !void {
        var reverse = false;
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) {
                const idx = y * self.width + x;
                if (DisplayCell.eql(self.prev[idx], self.next[idx])) {
                    x += 1;
                    continue;
                }
                try writer.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                while (x < self.width) : (x += 1) {
                    const i = y * self.width + x;
                    if (x != 0 and DisplayCell.eql(self.prev[i], self.next[i])) break;
                    if (self.next[i].reverse != reverse) {
                        try writer.writeAll(if (self.next[i].reverse) "\x1b[7m" else "\x1b[27m");
                        reverse = self.next[i].reverse;
                    }
                    try writer.writeAll(self.next[i].cell.slice());
                    self.prev[i] = self.next[i];
                }
            }
        }
        if (reverse) try writer.writeAll("\x1b[27m");
        try writer.writeAll("\x1b[0m\x1b[H");
    }
};

fn moveSelection(move: MoveOverlay) Selection {
    const w = move.source.width();
    const h = move.source.height();
    const right = move.left + @as(isize, @intCast(w - 1));
    const bottom = move.top + @as(isize, @intCast(h - 1));
    return .{
        .x0 = if (move.left < 0) 0 else @intCast(move.left),
        .y0 = if (move.top < 0) 0 else @intCast(move.top),
        .x1 = if (right < 0) 0 else @intCast(right),
        .y1 = if (bottom < 0) 0 else @intCast(bottom),
    };
}
