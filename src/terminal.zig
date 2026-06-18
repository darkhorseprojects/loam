const std = @import("std");
const builtin = @import("builtin");

const ioctl_iocgwinsz: c_int = switch (builtin.target.os.tag) {
    .linux => @as(c_int, @intCast(std.os.linux.T.IOCGWINSZ)),
    .macos, .ios, .tvos, .watchos, .driverkit, .maccatalyst, .visionos => @as(c_int, @intCast((0x40000000 | ((@sizeOf(std.posix.winsize) & 0x1fff) << 16) | (0x74 << 8) | 104))),
    .freebsd, .netbsd, .openbsd, .dragonfly => 0x40087468,
    else => @compileError("loam terminal size polling currently supports POSIX targets with TIOCGWINSZ"),
};

pub const Size = struct {
    cols: usize,
    rows: usize,
};

pub const Button = enum {
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
    other,
};

pub const MouseAction = enum {
    press,
    move,
    release,
};

pub const MouseEvent = struct {
    button: Button,
    action: MouseAction,
    x: usize,
    y: usize,
};

pub const Key = union(enum) {
    escape,
    q,
    b,
    n,
    c,
    r,
    v,
    space,
    digit: u8,
    other: u8,
};

pub const PasteEvent = struct {
    x: usize,
    y: usize,
    text: []const u8,
    positioned: bool,
};

pub const Event = union(enum) {
    key: Key,
    mouse: MouseEvent,
    resize: Size,
    paste: PasteEvent,
    frame,
    quit,
};

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    original_termios: std.posix.termios,
    writer: std.Io.File.Writer,
    writer_buf: []u8,
    active: bool = true,
    paste_buf: [8192]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Terminal {
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.cflag.CSIZE = .CS8;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;

        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);

        const writer_buf = try allocator.alloc(u8, 4096);
        var writer = std.Io.File.stdout().writer(io, writer_buf);

        try writer.interface.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[2J\x1b[H");
        try writer.interface.flush();

        return .{
            .allocator = allocator,
            .original_termios = original,
            .writer = writer,
            .writer_buf = writer_buf,
        };
    }

    pub fn deinit(self: *Terminal) !void {
        if (!self.active) return;
        self.active = false;
        defer self.allocator.free(self.writer_buf);
        try self.writer.interface.writeAll("\x1b[?2004l\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?25h\x1b[?1049l");
        try self.writer.interface.flush();
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original_termios);
    }

    pub fn size(self: *Terminal) !Size {
        _ = self;
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = std.c.ioctl(std.posix.STDIN_FILENO, ioctl_iocgwinsz, @intFromPtr(&ws));
        if (rc < 0) return error.TerminalSize;
        return .{ .cols = ws.col, .rows = ws.row };
    }

    pub fn readEvent(self: *Terminal, reader: *std.Io.Reader) !?Event {
        const b = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        if (b == 0x03) return .quit;

        if (b != 0x1b) return .{ .key = keyFromByte(b) };

        const second = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return .{ .key = .escape },
            else => return err,
        };
        if (second != '[') return .{ .key = .escape };

        var seq: [32]u8 = undefined;
        seq[0] = '[';
        var len: usize = 1;
        while (len < seq.len) : (len += 1) {
            const c = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            seq[len] = c;
            if (c == 'M' or c == 'm' or c == 'A' or c == 'B' or c == 'C' or c == 'D' or c == '~') break;
        }

        const used = @min(len + 1, seq.len);
        const payload = seq[0..used];

        if (std.mem.eql(u8, payload, "[A")) return .{ .key = .{ .other = 'u' } };
        if (std.mem.eql(u8, payload, "[B")) return .{ .key = .{ .other = 'd' } };
        if (std.mem.eql(u8, payload, "[C")) return .{ .key = .{ .other = 'r' } };
        if (std.mem.eql(u8, payload, "[D")) return .{ .key = .{ .other = 'l' } };

        if (std.mem.eql(u8, payload, "[200~")) {
            return try readBracketedPaste(self, reader);
        }

        if (payload.len > 1 and (payload[payload.len - 1] == 'M' or payload[payload.len - 1] == 'm')) {
            if (parseSgrMouse(payload)) |mouse| return .{ .mouse = mouse };
        }

        return .{ .key = .escape };
    }
};

fn readBracketedPaste(terminal: *Terminal, reader: *std.Io.Reader) !Event {
    const end = "\x1b[201~";
    var len: usize = 0;
    const buf = terminal.paste_buf[0..];

    while (len < buf.len) {
        const b = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (len >= end.len and std.mem.eql(u8, buf[len - end.len .. len], end)) {
            len -= end.len;
            break;
        }

        buf[len] = b;
        len += 1;
    }

    return .{ .paste = .{ .x = 0, .y = 0, .text = buf[0..len], .positioned = false } };
}

fn keyFromByte(b: u8) Key {
    return switch (b) {
        0x1b => .escape,
        'q' => .q,
        'b' => .b,
        'n' => .n,
        'c' => .c,
        'r' => .r,
        'v' => .v,
        ' ' => .space,
        '0'...'9' => .{ .digit = b - '0' },
        else => .{ .other = b },
    };
}

fn parseSgrMouse(seq: []const u8) ?MouseEvent {
    if (seq.len < 5) return null;
    const start = std.mem.indexOfScalar(u8, seq, '<') orelse return null;
    const end = seq.len - 1;
    const payload = seq[start + 1 .. end];
    const first = std.mem.indexOfScalar(u8, payload, ';') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, payload, first + 1, ';') orelse return null;

    const code = std.fmt.parseInt(i32, payload[0..first], 10) catch return null;
    const x = std.fmt.parseInt(usize, payload[first + 1 .. second], 10) catch return null;
    const y = std.fmt.parseInt(usize, payload[second + 1 ..], 10) catch return null;
    if (x == 0 or y == 0) return null;

    const release = seq[seq.len - 1] == 'm';
    const motion = (code & 0x20) != 0;
    const button_code = code & 0x03;

    const wheel = (code & 0x40) != 0;
    const button: Button = if (wheel) switch (code & 0x01) {
        0 => .wheel_up,
        else => .wheel_down,
    } else switch (button_code) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .other,
    };

    const action: MouseAction = if (release) .release else if (!wheel and motion) .move else .press;

    return .{
        .button = button,
        .action = action,
        .x = x - 1,
        .y = y - 1,
    };
}

pub fn sleepNanos(ns: i64) void {
    if (ns <= 0) return;
    var ts: std.posix.timespec = .{
        .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
    _ = std.posix.system.nanosleep(&ts, null);
}

pub fn nowSeconds() f64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1_000_000_000.0;
}

test "SGR mouse parser keeps terminal coordinates exact" {
    const press = parseSgrMouse("[<0;17;9M").?;
    try std.testing.expectEqual(Button.left, press.button);
    try std.testing.expectEqual(MouseAction.press, press.action);
    try std.testing.expectEqual(@as(usize, 16), press.x);
    try std.testing.expectEqual(@as(usize, 8), press.y);

    const drag = parseSgrMouse("[<32;18;10M").?;
    try std.testing.expectEqual(Button.left, drag.button);
    try std.testing.expectEqual(MouseAction.move, drag.action);
    try std.testing.expectEqual(@as(usize, 17), drag.x);
    try std.testing.expectEqual(@as(usize, 9), drag.y);

    const release = parseSgrMouse("[<0;18;10m").?;
    try std.testing.expectEqual(Button.left, release.button);
    try std.testing.expectEqual(MouseAction.release, release.action);
    try std.testing.expectEqual(@as(usize, 17), release.x);
    try std.testing.expectEqual(@as(usize, 9), release.y);
}
