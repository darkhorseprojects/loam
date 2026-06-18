const std = @import("std");
const types = @import("terminal_types.zig");

pub const alternate_screen_enter = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[2J\x1b[H";
pub const alternate_screen_exit = "\x1b[?2004l\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?25h\x1b[?1049l";

pub fn keyFromByte(b: u8) types.Key {
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

pub fn parseSgrMouse(seq: []const u8) ?types.MouseEvent {
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
    const button: types.Button = if (wheel) switch (code & 0x01) {
        0 => .wheel_up,
        else => .wheel_down,
    } else switch (button_code) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .other,
    };

    const action: types.MouseAction = if (release) .release else if (!wheel and motion) .move else .press;

    return .{
        .button = button,
        .action = action,
        .x = x - 1,
        .y = y - 1,
    };
}

test "SGR mouse parser keeps terminal coordinates exact" {
    const press = parseSgrMouse("[<0;17;9M").?;
    try std.testing.expectEqual(types.Button.left, press.button);
    try std.testing.expectEqual(types.MouseAction.press, press.action);
    try std.testing.expectEqual(@as(usize, 16), press.x);
    try std.testing.expectEqual(@as(usize, 8), press.y);

    const drag = parseSgrMouse("[<32;18;10M").?;
    try std.testing.expectEqual(types.Button.left, drag.button);
    try std.testing.expectEqual(types.MouseAction.move, drag.action);
    try std.testing.expectEqual(@as(usize, 17), drag.x);
    try std.testing.expectEqual(@as(usize, 9), drag.y);

    const release = parseSgrMouse("[<0;18;10m").?;
    try std.testing.expectEqual(types.Button.left, release.button);
    try std.testing.expectEqual(types.MouseAction.release, release.action);
    try std.testing.expectEqual(@as(usize, 17), release.x);
    try std.testing.expectEqual(@as(usize, 9), release.y);
}
