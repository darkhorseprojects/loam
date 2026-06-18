const builtin = @import("builtin");
const types = @import("terminal_types.zig");

const backend = switch (builtin.target.os.tag) {
    .windows => @import("terminal_windows.zig"),
    else => @import("terminal_posix.zig"),
};

pub const Size = types.Size;
pub const Button = types.Button;
pub const MouseAction = types.MouseAction;
pub const MouseEvent = types.MouseEvent;
pub const Key = types.Key;
pub const PasteEvent = types.PasteEvent;
pub const TextAction = types.TextAction;
pub const TextEvent = types.TextEvent;
pub const Event = types.Event;

pub const Terminal = backend.Terminal;
pub const sleepNanos = backend.sleepNanos;
pub const nowSeconds = backend.nowSeconds;

test {
    _ = @import("terminal_ansi.zig");
}
