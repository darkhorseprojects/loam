const std = @import("std");
const windows = std.os.windows;
const ansi = @import("terminal_ansi.zig");
const types = @import("terminal_types.zig");

const STD_INPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -11));
const WAIT_TIMEOUT: windows.DWORD = 0x00000102;

const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
const ENABLE_MOUSE_INPUT: windows.DWORD = 0x0010;
const ENABLE_EXTENDED_FLAGS: windows.DWORD = 0x0080;
const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: windows.DWORD = 0x0001;
const ENABLE_WRAP_AT_EOL_OUTPUT: windows.DWORD = 0x0002;

const COORD = extern struct {
    X: windows.SHORT,
    Y: windows.SHORT,
};

const SMALL_RECT = extern struct {
    Left: windows.SHORT,
    Top: windows.SHORT,
    Right: windows.SHORT,
    Bottom: windows.SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: windows.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn Sleep(dwMilliseconds: windows.DWORD) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) windows.BOOL;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) windows.BOOL;

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    input: windows.HANDLE,
    output: windows.HANDLE,
    original_input_mode: windows.DWORD,
    original_output_mode: windows.DWORD,
    writer: std.Io.File.Writer,
    writer_buf: []u8,
    active: bool = true,
    paste_buf: [8192]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Terminal {
        const input = GetStdHandle(STD_INPUT_HANDLE);
        const output = GetStdHandle(STD_OUTPUT_HANDLE);
        if (input == windows.INVALID_HANDLE_VALUE or output == windows.INVALID_HANDLE_VALUE) return error.ConsoleUnavailable;

        var input_mode: windows.DWORD = 0;
        var output_mode: windows.DWORD = 0;
        if (!GetConsoleMode(input, &input_mode).toBool()) return error.ConsoleUnavailable;
        if (!GetConsoleMode(output, &output_mode).toBool()) return error.ConsoleUnavailable;

        const raw_input = (input_mode | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS) & ~ENABLE_PROCESSED_INPUT;
        const raw_output = output_mode | ENABLE_PROCESSED_OUTPUT | ENABLE_WRAP_AT_EOL_OUTPUT | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING | windows.DISABLE_NEWLINE_AUTO_RETURN;
        if (!SetConsoleMode(input, raw_input).toBool()) return error.ConsoleMode;
        errdefer _ = SetConsoleMode(input, input_mode);
        if (!SetConsoleMode(output, raw_output).toBool()) return error.ConsoleMode;
        errdefer _ = SetConsoleMode(output, output_mode);

        const writer_buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(writer_buf);
        var writer = std.Io.File.stdout().writer(io, writer_buf);
        try writer.interface.writeAll(ansi.alternate_screen_enter);
        try writer.interface.flush();

        return .{
            .allocator = allocator,
            .input = input,
            .output = output,
            .original_input_mode = input_mode,
            .original_output_mode = output_mode,
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
        _ = SetConsoleMode(self.input, self.original_input_mode);
        _ = SetConsoleMode(self.output, self.original_output_mode);
    }

    pub fn size(self: *Terminal) !types.Size {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (!GetConsoleScreenBufferInfo(self.output, &info).toBool()) return error.TerminalSize;
        return .{
            .cols = @intCast(info.srWindow.Right - info.srWindow.Left + 1),
            .rows = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1),
        };
    }

    pub fn readEvent(self: *Terminal, reader: *std.Io.Reader) !?types.Event {
        if (!self.inputReady()) return null;
        const b = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        if (b == 0x03) return .quit;
        if (b != 0x1b) return .{ .key = ansi.keyFromByte(b) };

        const second = self.takeByteIfReady(reader) catch |err| switch (err) {
            error.EndOfStream => return .{ .key = .escape },
            else => return err,
        };
        if (second != '[') return .{ .key = .escape };

        var seq: [32]u8 = undefined;
        seq[0] = '[';
        var len: usize = 1;
        while (len < seq.len) : (len += 1) {
            const c = self.takeByteIfReady(reader) catch |err| switch (err) {
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

    fn inputReady(self: *Terminal) bool {
        return WaitForSingleObject(self.input, 0) != WAIT_TIMEOUT;
    }

    fn takeByteIfReady(self: *Terminal, reader: *std.Io.Reader) !u8 {
        if (!self.inputReady()) return error.EndOfStream;
        return reader.takeByte();
    }
};

fn readBracketedPaste(terminal: *Terminal, reader: *std.Io.Reader) !types.Event {
    const end = "\x1b[201~";
    var len: usize = 0;
    const buf = terminal.paste_buf[0..];

    while (len < buf.len) {
        const b = terminal.takeByteIfReady(reader) catch |err| switch (err) {
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
    Sleep(@intCast(@divTrunc(ns, std.time.ns_per_ms)));
}

pub fn nowSeconds() f64 {
    var counter: i64 = 0;
    var frequency: i64 = 0;
    if (!QueryPerformanceCounter(&counter).toBool() or !QueryPerformanceFrequency(&frequency).toBool()) return 0;
    return @as(f64, @floatFromInt(counter)) / @as(f64, @floatFromInt(frequency));
}
