const std = @import("std");
const zlua = @import("zlua");
const canvas_mod = @import("canvas.zig");
const terminal_mod = @import("terminal.zig");
const lua_bridge_mod = @import("lua_bridge.zig");
const brushes_mod = @import("brushes.zig");
const mcp_mod = @import("mcp.zig");
const version_mod = @import("version.zig");

const Canvas = canvas_mod.Canvas;
const Cell = canvas_mod.Cell;
const Selection = canvas_mod.Selection;
const Lua = zlua.Lua;
const LuaBridge = lua_bridge_mod.LuaBridge;
const BrushSet = brushes_mod.BrushSet;

const Point = struct {
    x: usize,
    y: usize,
};

const MoveState = struct {
    selection: Selection,
    anchor: Point,
};

const brush_scroll_cooldown_s = 0.35;
const escape_clear_countdown_s = 1.5;
const escape_clear_step_s = 0.5;
const escape_repeat_window_s = 0.75;

const App = struct {
    allocator: std.mem.Allocator,
    terminal: terminal_mod.Terminal,
    canvas: Canvas,
    bridge: LuaBridge,
    brushes: *BrushSet,
    clipboard: std.ArrayList(u8),
    move_cells: std.ArrayList(Cell),
    preview_buf: std.ArrayList(u8),
    selection: ?Selection = null,
    moving: ?MoveState = null,
    right_down: bool = false,
    right_anchor: ?Point = null,
    right_current: ?Point = null,
    left_down: bool = false,
    left_anchor: Point = .{ .x = 0, .y = 0 },
    left_moved: bool = false,
    escape_countdown: f64 = 0,
    escape_first_time: f64 = 0,
    escape_repeat_count: usize = 0,
    last_mouse: Point = .{ .x = 0, .y = 0 },
    last_brush_scroll_time: f64 = -brush_scroll_cooldown_s,
    last_size_sync: f64 = -1,

    fn render(self: *App, now: f64) !void {
        try self.syncTerminalSize(now);
        try self.canvas.render(&self.terminal.writer.interface);
        try self.drawCountdown();
        try self.drawPreview();
        try self.canvas.renderSelection(&self.terminal.writer.interface, self.selection);
        try self.terminal.writer.interface.flush();
    }

    fn cancelTransientInput(self: *App) void {
        self.cancelMove();
        self.selection = null;
        self.right_down = false;
        self.right_anchor = null;
        self.right_current = null;
        self.left_down = false;
        self.left_moved = false;
        self.canvas.clearStage();
    }

    fn startEscapeCountdown(self: *App) void {
        self.escape_countdown = escape_clear_countdown_s;
        self.escape_first_time = 0;
        self.escape_repeat_count = 0;
    }

    fn handleEscapePress(self: *App, now: f64) void {
        self.cancelTransientInput();
        if (self.escape_countdown > 0) return;
        if (self.escape_first_time == 0 or now - self.escape_first_time > escape_repeat_window_s) {
            self.escape_first_time = now;
            self.escape_repeat_count = 1;
            return;
        }

        self.escape_repeat_count += 1;
        if (self.escape_repeat_count >= 2) self.startEscapeCountdown();
    }

    fn cancelEscapeClear(self: *App) void {
        self.escape_countdown = 0;
        self.escape_first_time = 0;
        self.escape_repeat_count = 0;
    }

    fn updateEscapeClear(self: *App, dt: f64) void {
        if (self.escape_countdown <= 0) return;
        self.escape_countdown -= dt;
        if (self.escape_countdown <= 0) {
            self.escape_countdown = 0;
            self.canvas.clear();
        }
    }

    fn syncTerminalSize(self: *App, now: f64) !void {
        if (now - self.last_size_sync < 0.1) return;
        self.last_size_sync = now;
        const size = try self.terminal.size();
        if (size.cols == self.canvas.viewport.width and size.rows == self.canvas.viewport.height) return;
        self.cancelMove();
        try self.canvas.resize(size.cols, size.rows);
        self.selection = null;
        self.right_down = false;
        self.right_anchor = null;
        self.right_current = null;
    }

    fn drawCountdown(self: *App) !void {
        if (self.escape_countdown <= 0) return;
        const n = @as(usize, @intFromFloat(@ceil(self.escape_countdown / escape_clear_step_s)));
        const writer = &self.terminal.writer.interface;
        try writer.print("\x1b[1;1H\x1b[7m escape clear {d} \x1b[0m", .{n});
    }

    fn drawPreview(self: *App) !void {
        const box_w: usize = 24;
        const box_h: usize = 5;
        if (self.canvas.viewport.width < box_w + 2 or self.canvas.viewport.height < box_h + 2) return;
        if (!try self.bridge.preview(box_w, box_h, &self.preview_buf)) return;

        const x = self.canvas.viewport.width - box_w - 1;
        const y: usize = 1;
        const writer = &self.terminal.writer.interface;
        var rows = std.mem.splitScalar(u8, self.preview_buf.items, '\n');
        var row: usize = 0;
        while (row < box_h) : (row += 1) {
            const text = rows.next() orelse "";
            try writer.print("\x1b[{d};{d}H", .{ y + row + 1, x + 1 });
            try writePadded(writer, text, box_w);
        }
        try writer.writeAll("\x1b[0m");
    }

    fn cycleBrush(self: *App, delta: isize) !void {
        const previous = self.brushes.index;
        self.brushes.cycle(delta);
        self.loadActiveBrush() catch |err| {
            self.brushes.index = previous;
            return err;
        };
    }

    fn cycleBrushFromWheel(self: *App, delta: isize, time: f64) !void {
        if (time - self.last_brush_scroll_time < brush_scroll_cooldown_s) return;
        self.last_brush_scroll_time = time;
        try self.cycleBrush(delta);
    }

    fn loadActiveBrush(self: *App) !void {
        try self.bridge.loadBrush(self.brushes.activePath());
    }

    fn copySelection(self: *App) !void {
        const sel = self.selection orelse return;
        const text = try selectionText(self.allocator, &self.canvas, sel);
        self.clipboard.clearRetainingCapacity();
        try self.clipboard.appendSlice(self.allocator, text);

        copySystemClipboard(self.allocator, &self.terminal.writer.interface, text) catch {};
    }

    fn pasteAt(self: *App, x: usize, y: usize, dt: f64, time: f64) !void {
        if (self.clipboard.items.len == 0) return;
        try self.bridge.paint(.{ .paste = .{ .x = x, .y = y, .text = self.clipboard.items, .positioned = true } }, dt, time);
    }

    fn beginMove(self: *App, sel: Selection, at: Point) !void {
        self.move_cells.clearRetainingCapacity();
        var y = selectionTop(sel);
        while (y <= selectionBottom(sel)) : (y += 1) {
            var x = selectionLeft(sel);
            while (x <= selectionRight(sel)) : (x += 1) {
                try self.move_cells.append(self.allocator, self.canvas.getCell(x, y));
            }
        }
        self.moving = .{ .selection = sel, .anchor = at };
        try self.previewMove(at);
    }

    fn previewMove(self: *App, at: Point) !void {
        const moving = self.moving orelse return;
        self.canvas.clearStage();
        const dx = @as(isize, @intCast(at.x)) - @as(isize, @intCast(moving.anchor.x));
        const dy = @as(isize, @intCast(at.y)) - @as(isize, @intCast(moving.anchor.y));
        const left = selectionLeft(moving.selection);
        const top = selectionTop(moving.selection);
        const width = selectionWidth(moving.selection);
        const height = selectionHeight(moving.selection);

        var row: usize = 0;
        while (row < height) : (row += 1) {
            var col: usize = 0;
            while (col < width) : (col += 1) {
                self.stageWorldCell(left + col, top + row, Cell.space);
                const cell = self.move_cells.items[row * width + col];
                const world_x = @as(isize, @intCast(left + col)) + dx;
                const world_y = @as(isize, @intCast(top + row)) + dy;
                if (world_x >= 0 and world_y >= 0) self.stageWorldCell(@intCast(world_x), @intCast(world_y), cell);
            }
        }
    }

    fn finishMove(self: *App, at: Point) void {
        const moving = self.moving orelse return;
        const dx = @as(isize, @intCast(at.x)) - @as(isize, @intCast(moving.anchor.x));
        const dy = @as(isize, @intCast(at.y)) - @as(isize, @intCast(moving.anchor.y));
        const left = selectionLeft(moving.selection);
        const top = selectionTop(moving.selection);
        const width = selectionWidth(moving.selection);
        const height = selectionHeight(moving.selection);

        var row: usize = 0;
        while (row < height) : (row += 1) {
            var col: usize = 0;
            while (col < width) : (col += 1) self.canvas.setCell(left + col, top + row, Cell.space);
        }

        row = 0;
        while (row < height) : (row += 1) {
            var col: usize = 0;
            while (col < width) : (col += 1) {
                const world_x = @as(isize, @intCast(left + col)) + dx;
                const world_y = @as(isize, @intCast(top + row)) + dy;
                if (world_x >= 0 and world_y >= 0) self.canvas.setCell(@intCast(world_x), @intCast(world_y), self.move_cells.items[row * width + col]);
            }
        }

        self.canvas.clearStage();
        self.move_cells.clearRetainingCapacity();
        self.moving = null;
        self.selection = null;
    }

    fn cancelMove(self: *App) void {
        if (self.moving == null) return;
        self.canvas.clearStage();
        self.move_cells.clearRetainingCapacity();
        self.moving = null;
    }

    fn stageWorldCell(self: *App, world_x: usize, world_y: usize, cell: Cell) void {
        if (world_x < self.canvas.viewport.x or world_y < self.canvas.viewport.y) return;
        const vx = world_x - self.canvas.viewport.x;
        const vy = world_y - self.canvas.viewport.y;
        if (vx < self.canvas.viewport.width and vy < self.canvas.viewport.height) self.canvas.setStageCell(vx, vy, cell);
    }

    fn handleEvent(self: *App, event: terminal_mod.Event, dt: f64, time: f64) !void {
        switch (event) {
            .key => |key| switch (key) {
                .q => return error.Quit,
                .escape => self.handleEscapePress(time),
                .c => {
                    self.cancelMove();
                    self.selection = null;
                    self.canvas.clear();
                },
                .r => {
                    self.cancelMove();
                    self.selection = null;
                    self.right_anchor = null;
                    self.right_current = null;
                },
                .v => try self.pasteAt(self.last_mouse.x, self.last_mouse.y, dt, time),
                .digit => try self.bridge.paint(.{ .key = key }, dt, time),
                else => self.cancelEscapeClear(),
            },
            .mouse => |mouse| {
                self.last_mouse = .{ .x = mouse.x, .y = mouse.y };
                const world_mouse = Point{ .x = self.canvas.viewportToWorldX(mouse.x), .y = self.canvas.viewportToWorldY(mouse.y) };

                try switch (mouse.button) {
                    .left => {
                        if (mouse.action == .press) {
                            self.left_down = true;
                            self.left_anchor = world_mouse;
                            self.left_moved = false;
                        } else if (mouse.action == .move and self.left_down) {
                            self.left_moved = true;
                        } else if (mouse.action == .release and self.left_down) {
                            if (!self.left_moved) {
                                self.selection = null;
                                self.right_anchor = null;
                                self.right_current = null;
                                self.right_down = false;
                                self.cancelMove();
                            }
                            self.left_down = false;
                        }

                        if (self.moving) |_| {
                            const at = Point{ .x = world_mouse.x, .y = world_mouse.y };
                            switch (mouse.action) {
                                .press, .move => try self.previewMove(at),
                                .release => self.finishMove(at),
                            }
                        } else if (mouse.action == .press and self.selection != null and self.selection.?.contains(world_mouse.x, world_mouse.y)) {
                            try self.beginMove(self.selection.?, world_mouse);
                        } else {
                            try self.bridge.paint(.{ .mouse = mouse }, dt, time);
                        }
                    },
                    .right => {
                        switch (mouse.action) {
                            .press => {
                                self.right_down = true;
                                self.right_anchor = world_mouse;
                                self.right_current = world_mouse;
                                self.selection = null;
                            },
                            .move => {
                                if (self.right_down) {
                                    self.right_current = world_mouse;
                                    self.selection = selectionBetween(self.right_anchor.?, self.right_current.?);
                                }
                            },
                            .release => {
                                if (self.right_down) {
                                    self.right_current = world_mouse;
                                    self.selection = selectionBetween(self.right_anchor.?, self.right_current.?);
                                    try self.copySelection();
                                }
                                self.right_down = false;
                                self.right_anchor = null;
                                self.right_current = null;
                            },
                        }
                    },
                    .middle => {
                        if (mouse.action == .press) try self.pasteAt(mouse.x, mouse.y, dt, time);
                    },
                    .wheel_up => self.cycleBrushFromWheel(-1, time),
                    .wheel_down => self.cycleBrushFromWheel(1, time),
                    .other => {},
                };
            },
            .resize => |size| {
                self.cancelMove();
                try self.canvas.resize(size.cols, size.rows);
                self.selection = null;
            },
            .paste => |paste| {
                self.clipboard.clearRetainingCapacity();
                try self.clipboard.appendSlice(self.allocator, paste.text);
                const at = if (paste.positioned) Point{ .x = paste.x, .y = paste.y } else self.last_mouse;
                try self.pasteAt(at.x, at.y, dt, time);
            },
            .frame => {},
            .quit => return error.Quit,
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var initial_brush: ?[]const u8 = null;
    var list_only = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--mcp")) {
            try mcp_mod.run(init);
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try usage();
            return;
        }
        if (std.mem.eql(u8, arg, "--list")) {
            list_only = true;
        } else if (std.mem.startsWith(u8, arg, "--brush=")) {
            initial_brush = arg["--brush=".len..];
        } else if (std.mem.eql(u8, arg, "--brush")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("--brush requires a folder-relative name or file stem\n\n", .{});
                try usage();
                return error.InvalidArguments;
            }
            initial_brush = args[i];
        } else {
            std.debug.print("unknown argument: {s}\n\n", .{arg});
            try usage();
            return error.InvalidArguments;
        }
    }

    var brushes = try BrushSet.init(arena, init.io, init.environ_map, "brushes");
    defer brushes.deinit();
    if (initial_brush) |name| try brushes.select(name);

    if (list_only) {
        brushes.list();
        return;
    }

    var terminal = try terminal_mod.Terminal.init(arena, init.io);

    const size = try terminal.size();
    var canvas = try Canvas.init(arena, size.cols, size.rows);

    var prng = std.Random.DefaultPrng.init(0x10a57_5eed);
    const rng = prng.random();

    var lua = try Lua.init(init.gpa);
    defer lua.deinit();
    lua.openLibs();

    const bridge = LuaBridge.init(arena, init.gpa, init.io, lua, &canvas, rng);

    var app = App{
        .allocator = arena,
        .terminal = terminal,
        .canvas = canvas,
        .bridge = bridge,
        .brushes = &brushes,
        .clipboard = .empty,
        .move_cells = .empty,
        .preview_buf = .empty,
    };
    app.bridge.canvas = &app.canvas;
    app.bridge.register();
    try app.bridge.loadBrush(brushes.activePath());
    defer app.terminal.deinit() catch {};
    defer app.canvas.deinit();

    var stdin_file = std.Io.File.stdin();
    var input_buf: [4096]u8 = undefined;
    var reader = stdin_file.reader(init.io, &input_buf);

    var last_time = terminal_mod.nowSeconds();

    try app.render(last_time);

    while (true) {
        while (try app.terminal.readEvent(&reader.interface)) |event| {
            const now = terminal_mod.nowSeconds();
            const dt = @min(now - last_time, 0.05);
            last_time = now;
            app.handleEvent(event, dt, now) catch |err| switch (err) {
                error.Quit => return,
                else => return err,
            };
            try app.render(now);
        }

        const now = terminal_mod.nowSeconds();
        const dt = @min(now - last_time, 0.05);
        last_time = now;

        const had_countdown = app.escape_countdown > 0;
        app.updateEscapeClear(dt);
        if (had_countdown) {
            try app.render(now);
        } else if (app.bridge.wantsFrames()) {
            try app.bridge.paint(.frame, dt, now);
            try app.render(now);
        }
        terminal_mod.sleepNanos(16 * std.time.ns_per_ms);
    }
}

fn usage() !void {
    std.debug.print("loam v{s} — lua-scripted ascii particle painter\n", .{version_mod.version});
    std.debug.print(
        \\usage:
        \\  loam
        \\  loam --brush=seed
        \\  loam --list
        \\  loam --mcp
        \\  zig build run -- --brush=seed
        \\
        \\controls:
        \\  number keys     brush-specific presets / toggles
        \\  scroll wheel     change brush
        \\  left drag       paint with the active lua brush
        \\  right drag      select a rectangular ascii box
        \\  right release   copy the selected box to the system clipboard
        \\  middle click    paste the internal clipboard as a paste event
        \\  v               paste at the last mouse position
        \\  c               clear the canvas and particles
        \\  r               clear the selection
        \\  q               quit
        \\  hold esc        clear after countdown
        \\
        \\
    , .{});
}

fn selectionBetween(a: Point, b: Point) Selection {
    return .{
        .x0 = a.x,
        .y0 = a.y,
        .x1 = b.x,
        .y1 = b.y,
    };
}

fn selectionLeft(sel: Selection) usize {
    return @min(sel.x0, sel.x1);
}

fn selectionRight(sel: Selection) usize {
    return @max(sel.x0, sel.x1);
}

fn selectionTop(sel: Selection) usize {
    return @min(sel.y0, sel.y1);
}

fn selectionBottom(sel: Selection) usize {
    return @max(sel.y0, sel.y1);
}

fn selectionWidth(sel: Selection) usize {
    return selectionRight(sel) - selectionLeft(sel) + 1;
}

fn selectionHeight(sel: Selection) usize {
    return selectionBottom(sel) - selectionTop(sel) + 1;
}

fn selectionText(allocator: std.mem.Allocator, canvas: *const Canvas, sel: Selection) ![]u8 {
    const x0 = @min(sel.x0, sel.x1);
    const x1 = @max(sel.x0, sel.x1);
    const y0 = @min(sel.y0, sel.y1);
    const y1 = @max(sel.y0, sel.y1);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            try out.appendSlice(allocator, canvas.get(x, y));
        }
        if (y != y1) try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

fn repeat(writer: *std.Io.Writer, ch: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(ch);
}

fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    const n = @min(text.len, width);
    try writer.writeAll(text[0..n]);
    try repeat(writer, ' ', width - n);
}

fn copySystemClipboard(allocator: std.mem.Allocator, writer: *std.Io.Writer, text: []const u8) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);

    _ = std.base64.standard.Encoder.encode(encoded, text);
    try writer.print("\x1b]52;c;{s}\x07", .{encoded});
    try writer.flush();
}
