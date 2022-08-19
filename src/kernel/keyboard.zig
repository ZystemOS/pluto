const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const is_test = builtin.is_test;
const arch = if (is_test) @import("arch_mock") else @import("arch");

/// An arbitrary number of keys to remember before dropping any more that arrive. Is a power of two so we can use nice overflowing addition
pub const QUEUE_SIZE = 32;

/// The position of a key on a keyboard using the qwerty layout. This does not determine the key pressed, just the position on the keyboard.
pub const KeyPosition = enum(u7) {
    ESC,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    PRINT_SCREEN,
    SCROLL_LOCK,
    PAUSE,
    BACKTICK,
    ONE,
    TWO,
    THREE,
    FOUR,
    FIVE,
    SIX,
    SEVEN,
    EIGHT,
    NINE,
    ZERO,
    HYPHEN,
    EQUALS,
    BACKSPACE,
    TAB,
    Q,
    W,
    E,
    R,
    T,
    Y,
    U,
    I,
    O,
    P,
    LEFT_BRACKET,
    RIGHT_BRACKET,
    ENTER,
    CAPS_LOCK,
    A,
    S,
    D,
    F,
    G,
    H,
    J,
    K,
    L,
    SEMICOLON,
    APOSTROPHE,
    HASH,
    LEFT_SHIFT,
    BACKSLASH,
    Z,
    X,
    C,
    V,
    B,
    N,
    M,
    COMMA,
    DOT,
    FORWARD_SLASH,
    RIGHT_SHIFT,
    LEFT_CTRL,
    SPECIAL,
    LEFT_ALT,
    SPACE,
    RIGHT_ALT,
    FN,
    SPECIAL2,
    RIGHT_CTRL,
    INSERT,
    HOME,
    PAGE_UP,
    DELETE,
    END,
    PAGE_DOWN,
    LEFT_ARROW,
    UP_ARROW,
    DOWN_ARROW,
    RIGHT_ARROW,
    NUM_LOCK,
    KEYPAD_SLASH,
    KEYPAD_ASTERISK,
    KEYPAD_MINUS,
    KEYPAD_7,
    KEYPAD_8,
    KEYPAD_9,
    KEYPAD_PLUS,
    KEYPAD_4,
    KEYPAD_5,
    KEYPAD_6,
    KEYPAD_1,
    KEYPAD_2,
    KEYPAD_3,
    KEYPAD_ENTER,
    KEYPAD_0,
    KEYPAD_DOT,
};

/// A keyboard action, either a press or release
pub const KeyAction = struct {
    /// The position of the key
    position: KeyPosition,
    /// Whether it was a release or press
    released: bool,
};

/// The type used to index the keyboard queue
const QueueIndex = std.meta.Int(.unsigned, std.math.log2(QUEUE_SIZE));

/// A keyboard buffer that stores keyboard actions. This corresponds to a single hardware keyboard
pub const Keyboard = struct {
    /// A circular queue storing key presses until full
    queue: [QUEUE_SIZE]KeyAction,
    /// The front of the queue i.e. the next item to be dequeued
    queue_front: QueueIndex,
    /// The end of the queue i.e. where the next item is enqueued
    queue_end: QueueIndex,

    ///
    /// Initialise a keyboard with an empty key buffer
    ///
    /// Return: Keyboard
    ///     They keyboard created
    ///
    pub fn init() Keyboard {
        return .{
            .queue = [_]KeyAction{undefined} ** QUEUE_SIZE,
            .queue_front = 0,
            .queue_end = 0,
        };
    }

    ///
    /// Check if the keyboard queue is empty
    ///
    /// Arguments:
    ///     self: *const Keyboard - The keyboard to check
    ///
    /// Return: bool
    ///     True if the keyboard queue is empty, else false
    ///
    pub fn isEmpty(self: *const Keyboard) bool {
        return self.queue_end == self.queue_front;
    }

    ///
    /// Check if the keyboard queue is full
    ///
    /// Arguments:
    ///     self: *const Keyboard - The keyboard to check
    ///
    /// Return: bool
    ///     True if the keyboard queue is full, else false
    ///
    pub fn isFull(self: *const Keyboard) bool {
        var end_plus_one: QueueIndex = undefined;
        // This is a circular queue so overflow is allowed
        _ = @addWithOverflow(QueueIndex, self.queue_end, 1, &end_plus_one);
        return end_plus_one == self.queue_front;
    }

    ///
    /// Add a keyboard action to the keyboard's queue
    ///
    /// Arguments:
    ///     self: *Keyboard - The keyboard whose queue it should be added to
    ///     key: KeyAction - The action to add
    ///
    /// Return: bool
    ///     True if there was room for the key, else false
    ///
    pub fn writeKey(self: *Keyboard, key: KeyAction) bool {
        if (!self.isFull()) {
            self.queue[self.queue_end] = key;
            _ = @addWithOverflow(QueueIndex, self.queue_end, 1, &self.queue_end);
            return true;
        }
        return false;
    }

    ///
    /// Read and remove the next key from the keyboard's queue
    ///
    /// Arguments:
    ///     self: *Keyboard - The keyboard to get and remove the key from
    ///
    /// Return: ?KeyAction
    ///     The first keyboard action in the queue, else null if there were none
    ///
    pub fn readKey(self: *Keyboard) ?KeyAction {
        if (self.isEmpty()) return null;
        const key = self.queue[self.queue_front];
        _ = @addWithOverflow(QueueIndex, self.queue_front, 1, &self.queue_front);
        return key;
    }

    test "init" {
        const keyboard = Keyboard.init();
        try testing.expectEqual(keyboard.queue_front, 0);
        try testing.expectEqual(keyboard.queue_end, 0);
    }

    test "isEmpty" {
        var keyboard = Keyboard.init();
        try testing.expect(keyboard.isEmpty());

        keyboard.queue_end += 1;
        try testing.expect(!keyboard.isEmpty());

        keyboard.queue_front += 1;
        try testing.expect(keyboard.isEmpty());

        keyboard.queue_end = std.math.maxInt(QueueIndex);
        keyboard.queue_front = 0;
        try testing.expect(!keyboard.isEmpty());

        keyboard.queue_front = std.math.maxInt(QueueIndex);
        try testing.expect(keyboard.isEmpty());
    }

    test "isFull" {
        var keyboard = Keyboard.init();
        try testing.expect(!keyboard.isFull());

        keyboard.queue_end += 1;
        try testing.expect(!keyboard.isFull());

        keyboard.queue_front += 1;
        try testing.expect(!keyboard.isFull());

        keyboard.queue_end = 0;
        try testing.expect(keyboard.isFull());

        keyboard.queue_front = 0;
        keyboard.queue_end = std.math.maxInt(QueueIndex);
        try testing.expect(keyboard.isFull());
    }

    test "writeKey" {
        var keyboard = Keyboard.init();

        comptime var i = 0;
        inline while (i < QUEUE_SIZE - 1) : (i += 1) {
            try testing.expectEqual(keyboard.writeKey(.{
                .position = @intToEnum(KeyPosition, i),
                .released = false,
            }), true);
            try testing.expectEqual(keyboard.queue[i].position, @intToEnum(KeyPosition, i));
            try testing.expectEqual(keyboard.queue_end, i + 1);
            try testing.expectEqual(keyboard.queue_front, 0);
        }

        try testing.expectEqual(keyboard.writeKey(.{
            .position = @intToEnum(KeyPosition, 33),
            .released = false,
        }), false);
        try testing.expect(keyboard.isFull());
    }

    test "readKey" {
        var keyboard = Keyboard.init();

        comptime var i = 0;
        inline while (i < QUEUE_SIZE - 1) : (i += 1) {
            try testing.expectEqual(keyboard.writeKey(.{
                .position = @intToEnum(KeyPosition, i),
                .released = false,
            }), true);
        }

        i = 0;
        inline while (i < QUEUE_SIZE - 1) : (i += 1) {
            try testing.expectEqual(keyboard.readKey().?.position, @intToEnum(KeyPosition, i));
            try testing.expectEqual(keyboard.queue_end, QUEUE_SIZE - 1);
            try testing.expectEqual(keyboard.queue_front, i + 1);
        }

        try testing.expect(keyboard.isEmpty());
        try testing.expectEqual(keyboard.readKey(), null);
    }
};

/// The registered keyboards
var keyboards: ArrayList(*Keyboard) = undefined;

///
/// Get the keyboard associated with an ID
///
/// Arguments:
///     id: usize - The ID of the keyboard to get
///
/// Return: ?*Keyboard
///     The keyboard associated with the ID, or null if there isn't one
///
pub fn getKeyboard(id: usize) ?*Keyboard {
    if (keyboards.items.len <= id) {
        return null;
    }
    return keyboards.items[id];
}

///
/// Add a keyboard to list of known keyboards
///
/// Arguments:
///     kb: *Keyboard - The keyboard to add
///
/// Error: std.mem.Allocator.Error
///     OutOfMemory - Adding the keyboard to the list failed due to there not being enough memory free
///
pub fn addKeyboard(kb: *Keyboard) Allocator.Error!void {
    try keyboards.append(kb);
}

///
/// Initialise the keyboard system and the architecture's keyboard
///
/// Arguments:
///     allocator: std.mem.Allocator - The allocator to initialise the keyboard list and architecture keyboard with
///
/// Return: ?*Keyboard
///     The architecture keyboard found, else null if one wasn't detected
///
/// Error: std.mem.Allocator.Error
///     OutOfMemory - There wasn't enough memory to initialise the keyboard list or the architecture keyboard
///
pub fn init(allocator: Allocator) Allocator.Error!?*Keyboard {
    keyboards = ArrayList(*Keyboard).init(allocator);
    return arch.initKeyboard(allocator);
}

test {
    _ = Keyboard.init();
}
