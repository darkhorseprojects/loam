const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("terminal_ansi.zig");
const types = @import("terminal_types.zig");

const ioctl_iocgwinsz: c_int = switch (builtin.target.os.tag) {
    .linux => @as(c_int, @intCast(std.os.linux.T.IOCGWINSZ)),
    .macos, .ios, .tvos, .watchos, .driverkit, .maccatalyst, .visionos => @as(c_int, @intCast((0x40000000 | ((@sizeOf(std.posix.winsize) & 0x1fff) << 16) | (0x74 << 8) | 104))),
    .freebsd, .netbsd, .openbsd, .dragonfly => 0x40087468,
    else => @compileError("loam POSIX terminal backend supports Linux, macOS, and BSD TIOCGWINSZ targets"),
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
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;

        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);

        const writer_buf = try allocator.alloc(u8, 4096);
        var writer = std.Io.File.stdout().writer(io, writer_buf);
        try writer.interface.writeAll(ansi.alternate_screen_enter);
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
        try self.writer.interface.writeAll(ansi.alternate_screen_exit);
        try self.writer.interface.flush();
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original_termios);
    }

    pub fn size(self: *Terminal) !types.Size {
        _ = self;
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = std.c.ioctl(std.posix.STDIN_FILENO, ioctl_iocgwinsz, @intFromPtr(&ws));
        if (rc < 0) return error.TerminalSize;
        return .{ .cols = ws.col, .rows = ws.row };
    }

    pub fn readEvent(self: *Terminal, reader: *std.Io.Reader) !?types.Event {
        const b = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        if (b == 0x03) return .quit;
        if (b != 0x1b) return .{ .key = ansi.keyFromByte(b) };

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
        if (std.mem.eql(u8, payload, "[200~")) return try readBracketedPaste(self, reader);
        if (payload.len > 1 and (payload[payload.len - 1] == 'M' or payload[payload.len - 1] == 'm')) {
            if (ansi.parseSgrMouse(payload)) |mouse| return .{ .mouse = mouse };
        }

        return .{ .key = .escape };
    }
};

fn readBracketedPaste(terminal: *Terminal, reader: *std.Io.Reader) !types.Event {
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
