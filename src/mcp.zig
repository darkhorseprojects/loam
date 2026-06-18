const std = @import("std");
const JsonValue = std.json.Value;
const version_mod = @import("version.zig");

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
        const response = handleMessage(allocator, init.io, parsed.value) catch |err| try errorResponse(allocator, parsed.value, @errorName(err));
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
            "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"tools\":[{{\"name\":\"loam_apply_selection\",\"description\":\"Apply loam-style rectangular character placement to a text file.\",\"inputSchema\":{{\"type\":\"object\",\"required\":[\"input_file\",\"selection\",\"placement_char\"],\"properties\":{{\"input_file\":{{\"type\":\"string\"}},\"output_file\":{{\"type\":\"string\"}},\"placement_char\":{{\"type\":\"string\"}},\"selection\":{{\"type\":\"object\",\"required\":[\"line\",\"column\",\"width\",\"height\"],\"properties\":{{\"line\":{{\"type\":\"integer\",\"minimum\":1}},\"column\":{{\"type\":\"integer\",\"minimum\":1}},\"width\":{{\"type\":\"integer\",\"minimum\":1}},\"height\":{{\"type\":\"integer\",\"minimum\":1}}}}}}}}}}]}}}}",
            .{std.json.fmt(id, .{})},
        );
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const params = asObject(obj.get("params") orelse return error.MissingParams) orelse return error.MissingParams;
        const name = asString(params.get("name") orelse return error.MissingToolName) orelse return error.MissingToolName;
        if (!std.mem.eql(u8, name, "loam_apply_selection")) return error.UnknownTool;
        const args = asObject(params.get("arguments") orelse return error.MissingArguments) orelse return error.MissingArguments;
        const result = try applySelectionTool(allocator, io, args);
        return try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":false}}}}",
            .{ std.json.fmt(id, .{}), std.json.fmt(result, .{}) },
        );
    }

    return error.UnknownMethod;
}

fn errorResponse(allocator: std.mem.Allocator, message: JsonValue, text: []const u8) !?[]u8 {
    const id = if (asObject(message)) |obj| obj.get("id") orelse JsonValue.null else JsonValue.null;
    return try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{{\"code\":-32000,\"message\":{f}}}}}",
        .{ std.json.fmt(id, .{}), std.json.fmt(text, .{}) },
    );
}

fn applySelectionTool(allocator: std.mem.Allocator, io: std.Io, args: std.json.ObjectMap) ![]const u8 {
    const input_file = asString(args.get("input_file") orelse return error.MissingInputFile) orelse return error.MissingInputFile;
    const placement = asString(args.get("placement_char") orelse return error.MissingPlacementChar) orelse return error.MissingPlacementChar;
    if (placement.len == 0) return error.EmptyPlacementChar;

    const selection = asObject(args.get("selection") orelse return error.MissingSelection) orelse return error.MissingSelection;
    const line = asUsize(selection.get("line") orelse return error.MissingLine);
    const column = asUsize(selection.get("column") orelse return error.MissingColumn);
    const width = asUsize(selection.get("width") orelse return error.MissingWidth);
    const height = asUsize(selection.get("height") orelse return error.MissingHeight);

    const input = try readFile(allocator, io, input_file);
    const output = try applyRectangle(allocator, input, line, column, width, height, placement);

    if (args.get("output_file")) |value| {
        if (asString(value)) |path| try writeFile(io, path, output);
    }

    return output;
}

fn applyRectangle(allocator: std.mem.Allocator, input: []const u8, line: usize, column: usize, width: usize, height: usize, placement: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var row: usize = 1;
    while (lines.next()) |src_line| : (row += 1) {
        if (row > 1) try out.append(allocator, '\n');
        if (row < line or row >= line + height) {
            try out.appendSlice(allocator, src_line);
            continue;
        }

        const start = column - 1;
        const replace_end = start + width;
        const prefix_len = @min(start, src_line.len);
        try out.appendSlice(allocator, src_line[0..prefix_len]);
        if (src_line.len < start) try appendSpaces(allocator, &out, start - src_line.len);
        var i: usize = 0;
        while (i < width) : (i += 1) try out.appendSlice(allocator, placement);
        if (src_line.len > replace_end) try out.appendSlice(allocator, src_line[replace_end..]);
    }

    return out.toOwnedSlice(allocator);
}

fn appendSpaces(allocator: std.mem.Allocator, out: *std.ArrayList(u8), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.append(allocator, ' ');
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
