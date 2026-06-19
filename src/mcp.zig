const std = @import("std");
const JsonValue = std.json.Value;
const version_mod = @import("version.zig");

const Point = struct { line: usize, column: usize };
const Rect = struct { line: usize, column: usize, width: usize, height: usize };
const Mode = enum { fill, path };

pub fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    var stdin_file = std.Io.File.stdin();
    var input_buf: [8192]u8 = undefined;
    var reader = stdin_file.reader(init.io, &input_buf);
    var output_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buf);

    while (true) {
        const body = readMcpBody(allocator, &reader.interface) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(JsonValue, allocator, body, .{}) catch continue;
        defer parsed.deinit();
        const response = try handleMessage(allocator, init.io, parsed.value);
        if (response) |json| try writeMcp(&stdout.interface, json);
    }
}

fn readMcpBody(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var header = std.ArrayList(u8).empty;
    defer header.deinit(allocator);
    while (true) {
        const b = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        try header.append(allocator, b);
        if (std.mem.endsWith(u8, header.items, "\r\n\r\n")) break;
    }

    const prefix = "Content-Length:";
    const at = std.mem.indexOf(u8, header.items, prefix) orelse return error.MissingContentLength;
    var start = at + prefix.len;
    while (start < header.items.len and std.ascii.isWhitespace(header.items[start])) : (start += 1) {}
    var end = start;
    while (end < header.items.len and std.ascii.isDigit(header.items[end])) : (end += 1) {}
    const len = try std.fmt.parseInt(usize, header.items[start..end], 10);

    const body = try allocator.alloc(u8, len);
    for (body) |*b| b.* = try reader.takeByte();
    return body;
}

fn writeMcp(writer: *std.Io.Writer, json: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
    try writer.flush();
}

fn handleMessage(allocator: std.mem.Allocator, io: std.Io, message: JsonValue) !?[]u8 {
    const obj = asObject(message) orelse return null;
    const method = asString(obj.get("method") orelse return null) orelse return null;
    if (std.mem.eql(u8, method, "notifications/initialized")) return null;
    const id = obj.get("id") orelse JsonValue.null;

    if (std.mem.eql(u8, method, "initialize")) {
        return try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"loam\",\"version\":\"{s}\"}}}}}}",
            .{ std.json.fmt(id, .{}), version_mod.version },
        );
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        return try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"tools\":[{{\"name\":\"loam_apply_selection\",\"description\":\"Apply a loam-style fill or path to a text file. Can use an explicit rectangle, explicit points, or a connected target_char section.\",\"inputSchema\":{{\"type\":\"object\",\"required\":[\"input_file\",\"placement_char\"],\"properties\":{{\"input_file\":{{\"type\":\"string\"}},\"output_file\":{{\"type\":\"string\"}},\"mode\":{{\"type\":\"string\",\"enum\":[\"fill\",\"path\"]}},\"placement_char\":{{\"type\":\"string\",\"minLength\":1,\"maxLength\":1}},\"target_char\":{{\"type\":\"string\",\"minLength\":1,\"maxLength\":1}},\"target\":{{\"type\":\"object\",\"required\":[\"line\",\"column\"],\"properties\":{{\"line\":{{\"type\":\"integer\",\"minimum\":1}},\"column\":{{\"type\":\"integer\",\"minimum\":1}}}}}},\"selection\":{{\"type\":\"object\",\"properties\":{{\"line\":{{\"type\":\"integer\",\"minimum\":1}},\"column\":{{\"type\":\"integer\",\"minimum\":1}},\"width\":{{\"type\":\"integer\",\"minimum\":1}},\"height\":{{\"type\":\"integer\",\"minimum\":1}},\"points\":{{\"type\":\"array\",\"items\":{{\"type\":\"object\",\"required\":[\"line\",\"column\"],\"properties\":{{\"line\":{{\"type\":\"integer\",\"minimum\":1}},\"column\":{{\"type\":\"integer\",\"minimum\":1}}}}}}}}}}}},\"points\":{{\"type\":\"array\",\"items\":{{\"type\":\"object\",\"required\":[\"line\",\"column\"],\"properties\":{{\"line\":{{\"type\":\"integer\",\"minimum\":1}},\"column\":{{\"type\":\"integer\",\"minimum\":1}}}}}}}}}}}}}}]}}}}",
            .{std.json.fmt(id, .{})},
        );
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const params = asObject(obj.get("params") orelse return try jsonRpcError(allocator, id, "missing params")) orelse return try jsonRpcError(allocator, id, "params must be an object");
        const name = asString(params.get("name") orelse return try jsonRpcError(allocator, id, "missing tool name")) orelse return try jsonRpcError(allocator, id, "tool name must be a string");
        if (!std.mem.eql(u8, name, "loam_apply_selection")) return try jsonRpcError(allocator, id, "unknown tool");
        const args = asObject(params.get("arguments") orelse return try toolResult(allocator, id, "missing arguments", true)) orelse return try toolResult(allocator, id, "arguments must be an object", true);
        const result = applySelectionTool(allocator, io, args) catch |err| try std.fmt.allocPrint(allocator, "failed: {s}", .{@errorName(err)});
        return try toolResult(allocator, id, result, std.mem.startsWith(u8, result, "failed:"));
    }

    return try jsonRpcError(allocator, id, "unknown method");
}

fn jsonRpcError(allocator: std.mem.Allocator, id: JsonValue, text: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{{\"code\":-32000,\"message\":{f}}}}}", .{ std.json.fmt(id, .{}), std.json.fmt(text, .{}) });
}

fn toolResult(allocator: std.mem.Allocator, id: JsonValue, text: []const u8, is_error: bool) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":{s}}}}}", .{ std.json.fmt(id, .{}), std.json.fmt(text, .{}), if (is_error) "true" else "false" });
}

fn applySelectionTool(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) ![]const u8 {
    const input_file = asString(args.get("input_file") orelse return error.MissingInputFile) orelse return error.MissingInputFile;
    const placement = singleByte(asString(args.get("placement_char") orelse return error.MissingPlacementChar) orelse return error.MissingPlacementChar) orelse return error.PlacementCharMustBeOneByte;
    const target_char = if (args.get("target_char")) |value| singleByte(asString(value) orelse return error.TargetCharMustBeString) orelse return error.TargetCharMustBeOneByte else null;
    const mode = parseMode(if (args.get("mode")) |value| asString(value) orelse return error.ModeMustBeString else "fill") orelse return error.UnknownMode;

    const input = try readFile(allocator, io, input_file);
    defer allocator.free(input);
    var doc = try Document.init(allocator, input);
    defer doc.deinit();

    switch (mode) {
        .fill => try applyFill(allocator, &doc, args, target_char, placement),
        .path => try applyPath(allocator, &doc, args, target_char, placement),
    }

    const output = try doc.toOwnedText();
    if (args.get("output_file")) |value| if (asString(value)) |path| try writeFile(io, path, output);
    return output;
}

fn applyFill(allocator: std.mem.Allocator, doc: *Document, args: std.json.ObjectMap, target_char: ?u8, placement: u8) !void {
    if (args.get("selection")) |value| {
        const rect = parseRect(asObject(value) orelse return error.SelectionMustBeObject) orelse return error.SelectionNeedsRectangle;
        var y = rect.line;
        while (y < rect.line + rect.height) : (y += 1) {
            var x = rect.column;
            while (x < rect.column + rect.width) : (x += 1) {
                if (target_char) |target| {
                    if (doc.get(y, x) == target) try doc.set(y, x, placement);
                } else try doc.set(y, x, placement);
            }
        }
        return;
    }

    const target = target_char orelse return error.FillNeedsSelectionOrTargetChar;
    const seed = try targetPoint(allocator, doc, args, target);
    var section = try connectedSection(allocator, doc, seed, target);
    defer section.deinit(allocator);
    for (section.items) |p| try doc.set(p.line, p.column, placement);
}

fn applyPath(allocator: std.mem.Allocator, doc: *Document, args: std.json.ObjectMap, target_char: ?u8, placement: u8) !void {
    var pts = try parsePoints(allocator, args);
    defer pts.deinit(allocator);
    if (pts.items.len < 2) return error.PathNeedsAtLeastTwoPoints;
    var i: usize = 1;
    while (i < pts.items.len) : (i += 1) try drawSegment(doc, pts.items[i - 1], pts.items[i], target_char, placement);
}

fn targetPoint(allocator: std.mem.Allocator, doc: *const Document, args: std.json.ObjectMap, target: u8) !Point {
    if (args.get("target")) |value| {
        const obj = asObject(value) orelse return error.TargetMustBeObject;
        const p = Point{ .line = asUsize(obj.get("line") orelse return error.MissingTargetLine), .column = asUsize(obj.get("column") orelse return error.MissingTargetColumn) };
        if (doc.get(p.line, p.column) != target) return error.TargetPointDoesNotMatchTargetChar;
        return p;
    }

    const first = findFirst(doc, target) orelse return error.TargetCharNotFound;
    var section = try connectedSection(allocator, doc, first, target);
    defer section.deinit(allocator);
    var section_keys = std.AutoHashMap(u64, void).init(allocator);
    defer section_keys.deinit();
    for (section.items) |p| try section_keys.put(key(p), {});

    var y: usize = 1;
    while (y <= doc.rows.items.len) : (y += 1) {
        var x: usize = 1;
        while (x <= doc.rowLen(y)) : (x += 1) {
            const p = Point{ .line = y, .column = x };
            if (doc.get(y, x) == target and !section_keys.contains(key(p))) return error.TargetCharAmbiguousSpecifyTarget;
        }
    }
    return first;
}

fn findFirst(doc: *const Document, target: u8) ?Point {
    var y: usize = 1;
    while (y <= doc.rows.items.len) : (y += 1) {
        var x: usize = 1;
        while (x <= doc.rowLen(y)) : (x += 1) if (doc.get(y, x) == target) return .{ .line = y, .column = x };
    }
    return null;
}

fn connectedSection(allocator: std.mem.Allocator, doc: *const Document, seed: Point, target: u8) !std.ArrayList(Point) {
    var out = std.ArrayList(Point).empty;
    var queue = std.ArrayList(Point).empty;
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer queue.deinit(allocator);
    defer seen.deinit();

    try queue.append(allocator, seed);
    try seen.put(key(seed), {});
    var at: usize = 0;
    while (at < queue.items.len) : (at += 1) {
        const p = queue.items[at];
        try out.append(allocator, p);
        const neighbors = [_]Point{
            .{ .line = p.line -| 1, .column = p.column },
            .{ .line = p.line + 1, .column = p.column },
            .{ .line = p.line, .column = p.column -| 1 },
            .{ .line = p.line, .column = p.column + 1 },
        };
        for (neighbors) |n| {
            if (n.line == 0 or n.column == 0 or doc.get(n.line, n.column) != target or seen.contains(key(n))) continue;
            try seen.put(key(n), {});
            try queue.append(allocator, n);
        }
    }
    return out;
}

fn drawSegment(doc: *Document, a: Point, b: Point, target_char: ?u8, placement: u8) !void {
    var x0: isize = @intCast(a.column);
    var y0: isize = @intCast(a.line);
    const x1: isize = @intCast(b.column);
    const y1: isize = @intCast(b.line);
    const dx: isize = @intCast(@abs(x1 - x0));
    const sx: isize = if (x0 < x1) 1 else -1;
    const dy: isize = -@as(isize, @intCast(@abs(y1 - y0)));
    const sy: isize = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        const p = Point{ .line = @intCast(y0), .column = @intCast(x0) };
        if (target_char) |target| {
            if (doc.get(p.line, p.column) == target) try doc.set(p.line, p.column, placement);
        } else try doc.set(p.line, p.column, placement);
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
}

const Document = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList([]u8),

    fn init(allocator: std.mem.Allocator, text: []const u8) !Document {
        var rows = std.ArrayList([]u8).empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try rows.append(allocator, try allocator.dupe(u8, line));
        return .{ .allocator = allocator, .rows = rows };
    }

    fn deinit(self: *Document) void {
        for (self.rows.items) |row| self.allocator.free(row);
        self.rows.deinit(self.allocator);
    }

    fn rowLen(self: *const Document, line: usize) usize {
        if (line == 0 or line > self.rows.items.len) return 0;
        return self.rows.items[line - 1].len;
    }

    fn get(self: *const Document, line: usize, column: usize) u8 {
        if (line == 0 or column == 0 or line > self.rows.items.len) return ' ';
        const row = self.rows.items[line - 1];
        return if (column <= row.len) row[column - 1] else ' ';
    }

    fn set(self: *Document, line: usize, column: usize, char: u8) !void {
        if (line == 0 or column == 0) return;
        while (self.rows.items.len < line) try self.rows.append(self.allocator, try self.allocator.dupe(u8, ""));
        var row = self.rows.items[line - 1];
        if (row.len < column) {
            const old_len = row.len;
            row = try self.allocator.realloc(row, column);
            @memset(row[old_len..column], ' ');
            self.rows.items[line - 1] = row;
        }
        row[column - 1] = char;
    }

    fn toOwnedText(self: *const Document) ![]u8 {
        var out = std.ArrayList(u8).empty;
        for (self.rows.items, 0..) |row, i| {
            if (i > 0) try out.append(self.allocator, '\n');
            try out.appendSlice(self.allocator, row);
        }
        return out.toOwnedSlice(self.allocator);
    }
};

fn parseMode(text: []const u8) ?Mode {
    if (std.mem.eql(u8, text, "fill")) return .fill;
    if (std.mem.eql(u8, text, "path")) return .path;
    return null;
}

fn parseRect(obj: std.json.ObjectMap) ?Rect {
    return .{
        .line = asUsize(obj.get("line") orelse return null),
        .column = asUsize(obj.get("column") orelse return null),
        .width = asUsize(obj.get("width") orelse return null),
        .height = asUsize(obj.get("height") orelse return null),
    };
}

fn parsePoints(allocator: std.mem.Allocator, args: std.json.ObjectMap) !std.ArrayList(Point) {
    const value = args.get("points") orelse blk: {
        const selection = asObject(args.get("selection") orelse return error.PathNeedsPoints) orelse return error.SelectionMustBeObject;
        break :blk selection.get("points") orelse return error.PathNeedsPoints;
    };
    const array = asArray(value) orelse return error.PointsMustBeArray;
    var points = std.ArrayList(Point).empty;
    for (array.items) |item| {
        const obj = asObject(item) orelse return error.PointMustBeObject;
        try points.append(allocator, .{
            .line = asUsize(obj.get("line") orelse return error.MissingPointLine),
            .column = asUsize(obj.get("column") orelse return error.MissingPointColumn),
        });
    }
    return points;
}

fn key(p: Point) u64 {
    return (@as(u64, @intCast(p.line)) << 32) | @as(u64, @intCast(p.column));
}

fn singleByte(text: []const u8) ?u8 {
    return if (text.len == 1) text[0] else null;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);
    var list = std.ArrayList(u8).empty;
    try reader.interface.appendRemainingUnlimited(allocator, &list);
    return list.toOwnedSlice(allocator);
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn asObject(value: JsonValue) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn asArray(value: JsonValue) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn asString(value: JsonValue) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn asUsize(value: JsonValue) usize {
    return switch (value) {
        .integer => |v| @intCast(@max(v, 1)),
        .float => |v| @intFromFloat(@max(v, 1)),
        else => 1,
    };
}

pub fn main(init: std.process.Init) !void {
    try run(init);
}
