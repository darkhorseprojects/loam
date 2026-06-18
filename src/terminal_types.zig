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
    enter,
    backspace,
    digit: u8,
    other: u8,
};

pub const PasteEvent = struct {
    x: usize,
    y: usize,
    text: []const u8,
    positioned: bool,
};

pub const TextAction = enum {
    input,
    backspace,
    submit,
    cancel,
};

pub const TextEvent = struct {
    action: TextAction,
    text: []const u8,
};

pub const Event = union(enum) {
    key: Key,
    mouse: MouseEvent,
    resize: Size,
    paste: PasteEvent,
    text: TextEvent,
    frame,
    quit,
};
