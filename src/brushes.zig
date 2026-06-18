const std = @import("std");

pub const Brush = struct {
    path: []const u8,
    name: []const u8,
    glyph: []const u8,
};

pub const BrushSet = struct {
    allocator: std.mem.Allocator,
    items: []Brush,
    index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, dir_path: []const u8) !BrushSet {
        var paths = std.ArrayList([]const u8).empty;
        defer paths.deinit(allocator);

        try appendBrushDir(allocator, io, &paths, dir_path);
        try appendUserBrushDirs(allocator, io, env, &paths);
        try appendBrushDir(allocator, io, &paths, "/usr/local/share/loam/brushes");
        try appendBrushDir(allocator, io, &paths, "/usr/share/loam/brushes");

        if (paths.items.len == 0) return error.NoBrushesFound;
        std.mem.sort([]const u8, paths.items, {}, lessThanName);

        const items = try allocator.alloc(Brush, paths.items.len);
        for (paths.items, 0..) |path, i| {
            const data = try readFileAlloc(allocator, io, path);
            defer allocator.free(data);
            const file_stem = brushFileStem(path);

            items[i] = .{
                .path = path,
                .name = scanStringField(allocator, data, "name") orelse stem(allocator, file_stem) catch "brush",
                .glyph = scanStringField(allocator, data, "glyph") orelse "*",
            };
        }

        return .{ .allocator = allocator, .items = items };
    }

    pub fn deinit(self: *BrushSet) void {
        for (self.items) |brush| self.allocator.free(brush.path);
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn active(self: *const BrushSet) Brush {
        return self.items[self.index];
    }

    pub fn activePath(self: *const BrushSet) []const u8 {
        return self.items[self.index].path;
    }

    pub fn cycle(self: *BrushSet, delta: isize) void {
        if (self.items.len == 0) return;
        const len: isize = @intCast(self.items.len);
        const next = @mod(@as(isize, @intCast(self.index)) + delta, len);
        self.index = @intCast(next);
    }

    pub fn select(self: *BrushSet, needle: []const u8) !void {
        for (self.items, 0..) |brush, i| {
            if (std.mem.eql(u8, brush.path, needle) or std.mem.eql(u8, brush.name, needle) or std.mem.eql(u8, brushFileStem(brush.path), needle)) {
                self.index = i;
                return;
            }
        }
        return error.BrushNotFound;
    }

    pub fn list(self: *const BrushSet) void {
        for (self.items, 0..) |brush, i| {
            std.debug.print("{s}{s} {s} ({s})\n", .{
                if (i == self.index) "* " else "  ",
                brush.name,
                brush.glyph,
                brushFileStem(brush.path),
            });
        }
    }
};

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, brushFileStem(a), brushFileStem(b));
}

fn appendUserBrushDirs(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, paths: *std.ArrayList([]const u8)) !void {
    if (env.get("XDG_CONFIG_HOME")) |base| try appendJoinedBrushDir(allocator, io, paths, base, "loam/brushes");
    if (env.get("HOME")) |home| try appendJoinedBrushDir(allocator, io, paths, home, ".config/loam/brushes");
    if (env.get("XDG_DATA_HOME")) |base| try appendJoinedBrushDir(allocator, io, paths, base, "loam/brushes");
    if (env.get("HOME")) |home| try appendJoinedBrushDir(allocator, io, paths, home, ".local/share/loam/brushes");
}

fn appendJoinedBrushDir(allocator: std.mem.Allocator, io: std.Io, paths: *std.ArrayList([]const u8), base: []const u8, suffix: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, suffix });
    try appendBrushDir(allocator, io, paths, path);
}

fn appendBrushDir(allocator: std.mem.Allocator, io: std.Io, paths: *std.ArrayList([]const u8), dir_path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".lua")) {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            if (containsStem(paths.items, path)) {
                allocator.free(path);
                continue;
            }
            try paths.append(allocator, path);
        }
    }
}

fn containsStem(paths: []const []const u8, path: []const u8) bool {
    const needle = brushFileStem(path);
    for (paths) |existing| {
        if (std.mem.eql(u8, needle, brushFileStem(existing))) return true;
    }
    return false;
}

fn stem(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const end = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    return allocator.dupe(u8, path[0..end]);
}

fn brushFileStem(path: []const u8) []const u8 {
    const end = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const start = (std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse 0) + 1;
    return path[start..end];
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var list = std.ArrayList(u8).empty;
    try reader.interface.appendRemainingUnlimited(allocator, &list);
    return list.toOwnedSlice(allocator);
}

fn scanStringField(allocator: std.mem.Allocator, source: []const u8, field: []const u8) ?[]const u8 {
    var search_at: usize = 0;
    while (std.mem.indexOf(u8, source[search_at..], field)) |offset| {
        var at = search_at + offset + field.len;
        while (at < source.len and std.ascii.isWhitespace(source[at])) : (at += 1) {}
        if (at < source.len and source[at] == '=') {
            at += 1;
            while (at < source.len and std.ascii.isWhitespace(source[at])) : (at += 1) {}
            if (scanQuotedString(allocator, source, at)) |value| return value;
        }
        search_at += offset + field.len;
    }
    return null;
}

fn scanQuotedString(allocator: std.mem.Allocator, source: []const u8, at: usize) ?[]const u8 {
    if (at >= source.len or source[at] != '"') return null;
    var i = at + 1;
    const start = i;
    var escaped = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (escaped) {
            escaped = false;
        } else if (c == '\\') {
            escaped = true;
        } else if (c == '"') {
            return allocator.dupe(u8, source[start..i]) catch null;
        }
    }

    return null;
}
