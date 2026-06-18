const std = @import("std");
const canvas_mod = @import("canvas.zig");

const Canvas = canvas_mod.Canvas;
const Cell = canvas_mod.Cell;
const Particle = canvas_mod.Particle;
const Selection = canvas_mod.Selection;

const DisplayCell = struct {
    cell: Cell = Cell.space,
    reverse: bool = false,

    fn eql(a: DisplayCell, b: DisplayCell) bool {
        return a.reverse == b.reverse and a.cell.len == b.cell.len and std.mem.eql(u8, a.cell.slice(), b.cell.slice());
    }
};

pub const MoveOverlay = struct {
    source: Selection,
    left: isize,
    top: isize,
    width: usize,
    height: usize,
    cells: []const Cell,
};

pub const UiOverlay = struct {
    countdown: ?usize = null,
    preview: ?[]const u8 = null,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    prev: []DisplayCell,
    next: []DisplayCell,
    full_redraw: bool = true,

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
        self.full_redraw = true;
    }

    pub fn render(self: *Renderer, writer: *std.Io.Writer, canvas: *const Canvas, selection: ?Selection, move: ?MoveOverlay, ui: UiOverlay) !void {
        self.build(canvas, selection, move, ui);
        if (self.full_redraw) {
            try writer.writeAll("\x1b[2J");
            @memset(self.prev, DisplayCell{});
        }
        try self.flushDiff(writer);
        self.full_redraw = false;
    }

    fn build(self: *Renderer, canvas: *const Canvas, selection: ?Selection, move: ?MoveOverlay, ui: UiOverlay) void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                self.at(x, y).* = .{ .cell = Cell.init(canvas.cellAtViewport(x, y)), .reverse = false };
            }
        }

        self.applyParticles(canvas);
        if (move) |m| self.applyMove(canvas, m);
        self.applyPreview(ui.preview);
        self.applyCountdown(ui.countdown);
        self.applySelection(canvas, if (move) |m| translatedSelection(m) else selection);
    }

    fn at(self: *Renderer, x: usize, y: usize) *DisplayCell {
        return &self.next[y * self.width + x];
    }

    fn set(self: *Renderer, x: usize, y: usize, cell: Cell, reverse: bool) void {
        if (x >= self.width or y >= self.height) return;
        self.at(x, y).* = .{ .cell = cell, .reverse = reverse };
    }

    fn applyParticles(self: *Renderer, canvas: *const Canvas) void {
        for (canvas.particles()) |p| {
            const px: isize = @intFromFloat(@round(p.x));
            const py: isize = @intFromFloat(@round(p.y));
            const sx = px - @as(isize, @intCast(canvas.viewportX()));
            const sy = py - @as(isize, @intCast(canvas.viewportY()));
            if (sx < 0 or sy < 0) continue;
            self.set(@intCast(sx), @intCast(sy), p.glyph, false);
        }
    }

    fn applyMove(self: *Renderer, canvas: *const Canvas, move: MoveOverlay) void {
        const source_left = @min(move.source.x0, move.source.x1);
        const source_top = @min(move.source.y0, move.source.y1);

        var row: usize = 0;
        while (row < move.height) : (row += 1) {
            var col: usize = 0;
            while (col < move.width) : (col += 1) self.setWorld(canvas, source_left + col, source_top + row, Cell.space, false);
        }

        row = 0;
        while (row < move.height) : (row += 1) {
            var col: usize = 0;
            while (col < move.width) : (col += 1) {
                const x = move.left + @as(isize, @intCast(col));
                const y = move.top + @as(isize, @intCast(row));
                if (x >= 0 and y >= 0) self.setWorld(canvas, @intCast(x), @intCast(y), move.cells[row * move.width + col], false);
            }
        }
    }

    fn setWorld(self: *Renderer, canvas: *const Canvas, world_x: usize, world_y: usize, cell: Cell, reverse: bool) void {
        if (world_x < canvas.viewportX() or world_y < canvas.viewportY()) return;
        const x = world_x - canvas.viewportX();
        const y = world_y - canvas.viewportY();
        self.set(x, y, cell, reverse);
    }

    fn applyPreview(self: *Renderer, text: ?[]const u8) void {
        const frame = text orelse return;
        const box_w: usize = 24;
        const box_h: usize = 5;
        if (self.width < box_w + 2 or self.height < box_h + 2) return;
        const left = self.width - box_w - 1;
        const top: usize = 1;
        var rows = std.mem.splitScalar(u8, frame, '\n');
        var row: usize = 0;
        while (row < box_h) : (row += 1) {
            const src = rows.next() orelse "";
            var col: usize = 0;
            while (col < box_w) : (col += 1) {
                const glyph = if (col < src.len) src[col .. col + 1] else " ";
                self.set(left + col, top + row, Cell.init(glyph), false);
            }
        }
    }

    fn applyCountdown(self: *Renderer, countdown: ?usize) void {
        const n = countdown orelse return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " escape clear {d} ", .{n}) catch return;
        var x: usize = 0;
        while (x < text.len and x < self.width) : (x += 1) self.set(x, 0, Cell.init(text[x .. x + 1]), true);
    }

    fn applySelection(self: *Renderer, canvas: *const Canvas, selection: ?Selection) void {
        const sel = selection orelse return;
        const left = @max(@min(sel.x0, sel.x1), canvas.viewportX());
        const top = @max(@min(sel.y0, sel.y1), canvas.viewportY());
        const right = @min(@max(sel.x0, sel.x1), canvas.viewportX() + self.width -| 1);
        const bottom = @min(@max(sel.y0, sel.y1), canvas.viewportY() + self.height -| 1);
        if (left > right or top > bottom) return;
        var y = top;
        while (y <= bottom) : (y += 1) {
            var x = left;
            while (x <= right) : (x += 1) {
                const sx = x - canvas.viewportX();
                const sy = y - canvas.viewportY();
                self.at(sx, sy).reverse = true;
            }
        }
    }

    fn flushDiff(self: *Renderer, writer: *std.Io.Writer) !void {
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
                    const run_idx = y * self.width + x;
                    if (x != 0 and DisplayCell.eql(self.prev[run_idx], self.next[run_idx])) break;
                    const cell = self.next[run_idx];
                    if (cell.reverse != reverse) {
                        try writer.writeAll(if (cell.reverse) "\x1b[7m" else "\x1b[27m");
                        reverse = cell.reverse;
                    }
                    try writer.writeAll(cell.cell.slice());
                    self.prev[run_idx] = cell;
                }
            }
        }
        if (reverse) try writer.writeAll("\x1b[27m");
        try writer.writeAll("\x1b[0m\x1b[H");
    }
};

fn translatedSelection(move: MoveOverlay) Selection {
    const right = move.left + @as(isize, @intCast(move.width - 1));
    const bottom = move.top + @as(isize, @intCast(move.height - 1));
    return .{
        .x0 = if (move.left < 0) 0 else @intCast(move.left),
        .y0 = if (move.top < 0) 0 else @intCast(move.top),
        .x1 = if (right < 0) 0 else @intCast(right),
        .y1 = if (bottom < 0) 0 else @intCast(bottom),
    };
}
