const builtin = @import("builtin");
const build_options = @import("build_options");
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const log = std.log.scoped(.x86_keyboard);
const irq = @import("irq.zig");
const pic = @import("pic.zig");
const arch = if (builtin.is_test) @import(build_options.arch_mock_path ++ "arch_mock.zig") else @import("arch.zig");
const panic = @import("../../../panic.zig").panic;
const kb = @import("../../../keyboard.zig");
const Keyboard = kb.Keyboard;
const KeyPosition = kb.KeyPosition;
const KeyAction = kb.KeyAction;

/// The initialised keyboard
var keyboard: *Keyboard = undefined;
/// The number of keys pressed without a corresponding release
var pressed_keys: usize = 0;
/// If we're in the middle of a special key sequence (e.g. print_screen and arrow keys)
var special_sequence = false;
/// The number of release scan codes expected before registering a release event
/// This is used in special sequences since they end in a certain number of release scan codes
var expected_releases: usize = 0;
/// If a print_screen press is being processed
var on_print_screen = false;

///
/// Read a byte from the keyboard buffer
///
/// Return: u8
///     The byte waiting in the keyboard buffer
///
fn readKeyboardBuffer() u8 {
    return arch.in(u8, 0x60);
}

///
/// Parse a keyboard scan code and return the associated keyboard action.
/// Some keys require a specific sequence of scan codes so this function acts as a state machine
///
/// Arguments:
///     IN scan_code: u8 - The scan code from the keyboard
///
/// Return: ?KeyAction
///     The keyboard action resulting from processing the scan code, or null if the scan code doesn't result in a finished keyboard action
///
fn parseScanCode(scan_code: u8) ?KeyAction {
    var released = false;
    // The print screen key requires special processing since it uses a unique byte sequence
    if (on_print_screen or scan_code >= 128) {
        released = true;
        if (special_sequence or on_print_screen) {
            // Special sequences are followed by a certain number of release scan codes that should be ignored. Update the expected number
            if (expected_releases >= 1) {
                expected_releases -= 1;
                return null;
            }
        } else {
            if (pressed_keys == 0) {
                // A special sequence is started by a lone key release scan code
                special_sequence = true;
                return null;
            }
        }
    }
    // Cut off the top bit, which denotes that the key was released
    const key_code = @truncate(u7, scan_code);
    var key_pos: ?KeyPosition = null;
    if (special_sequence or on_print_screen) {
        if (!released) {
            // Most special sequences are followed by an extra key release byte
            expected_releases = 1;
        }
        switch (key_code) {
            72 => key_pos = KeyPosition.UP_ARROW,
            75 => key_pos = KeyPosition.LEFT_ARROW,
            77 => key_pos = KeyPosition.RIGHT_ARROW,
            80 => key_pos = KeyPosition.DOWN_ARROW,
            // First byte sent for the pause key
            29 => return null,
            42 => {
                // The print screen key is followed by five extra key release bytes
                key_pos = KeyPosition.PRINT_SCREEN;
                if (!released) {
                    on_print_screen = true;
                    expected_releases = 5;
                }
            },
            // Second and final byte sent for the pause key
            69 => {
                // The pause key is followed by two extra key release bytes
                key_pos = KeyPosition.PAUSE;
                if (!released) {
                    expected_releases = 2;
                }
            },
            82 => key_pos = KeyPosition.INSERT,
            71 => key_pos = KeyPosition.HOME,
            73 => key_pos = KeyPosition.PAGE_UP,
            83 => key_pos = KeyPosition.DELETE,
            79 => key_pos = KeyPosition.END,
            81 => key_pos = KeyPosition.PAGE_DOWN,
            53 => key_pos = KeyPosition.KEYPAD_SLASH,
            28 => key_pos = KeyPosition.KEYPAD_ENTER,
            56 => key_pos = KeyPosition.RIGHT_ALT,
            91 => key_pos = KeyPosition.SPECIAL,
            else => return null,
        }
    }
    key_pos = key_pos orelse switch (key_code) {
        1 => KeyPosition.ESC,
        // Number keys and second row
        2...28 => @intToEnum(KeyPosition, @enumToInt(KeyPosition.ONE) + (key_code - 2)),
        29 => KeyPosition.LEFT_CTRL,
        30...40 => @intToEnum(KeyPosition, @enumToInt(KeyPosition.A) + (key_code - 30)),
        41 => KeyPosition.BACKTICK,
        42 => KeyPosition.LEFT_SHIFT,
        43 => KeyPosition.HASH,
        44...54 => @intToEnum(KeyPosition, @enumToInt(KeyPosition.Z) + (key_code - 44)),
        55 => KeyPosition.KEYPAD_ASTERISK,
        56 => KeyPosition.LEFT_ALT,
        57 => KeyPosition.SPACE,
        58 => KeyPosition.CAPS_LOCK,
        59...68 => @intToEnum(KeyPosition, @enumToInt(KeyPosition.F1) + (key_code - 59)),
        69 => KeyPosition.NUM_LOCK,
        70 => KeyPosition.SCROLL_LOCK,
        71...73 => @intToEnum(KeyPosition, @enumToInt(KeyPosition.KEYPAD_7) + (key_code - 71)),
        74 => KeyPosition.KEYPAD_MINUS,
        75...77 => @intToEnum(KeyPosition, @enumToInt(KeyPosition.KEYPAD_4) + (key_code - 75)),
        78 => KeyPosition.KEYPAD_PLUS,
        79...81 => @intToEnum(KeyPosition, @enumToInt(KeyPosition.KEYPAD_1) + (key_code - 79)),
        82 => KeyPosition.KEYPAD_0,
        83 => KeyPosition.KEYPAD_DOT,
        86 => KeyPosition.BACKSLASH,
        87 => KeyPosition.F11,
        88 => KeyPosition.F12,
        else => null,
    };
    if (key_pos) |k| {
        // If we're releasing a key decrement the number of keys pressed, else increment it
        if (!released) {
            pressed_keys += 1;
        } else {
            pressed_keys -= 1;
            // Releasing a special key means we are no longer on that special key
            special_sequence = false;
        }
        return KeyAction{ .position = k, .released = released };
    }
    return null;
}

///
/// Register a keyboard action. Should only be called in response to a keyboard IRQ
///
/// Arguments:
///     IN ctx: *arch.CpuState - The state of the CPU when the keyboard action occurred
///
/// Return: usize
///     The stack pointer value to use when returning from the interrupt
///
fn onKeyEvent(ctx: *arch.CpuState) usize {
    const scan_code = readKeyboardBuffer();
    if (parseScanCode(scan_code)) |action| {
        if (!keyboard.writeKey(action)) {
            log.notice("No room for keyboard action {}\n", .{action});
        }
    }
    return @ptrToInt(ctx);
}

///
/// Initialise the PS/2 keyboard
///
/// Arguments:
///     IN allocator: *Allocator - The allocator to use to create the keyboard instance
///
/// Return: *Keyboard
///     The keyboard created
///
/// Error: std.mem.Allocator.Error
///     OutOfMemory - There isn't enough memory to allocate the keyboard instance
///
pub fn init(allocator: *Allocator) Allocator.Error!*Keyboard {
    irq.registerIrq(pic.IRQ_KEYBOARD, onKeyEvent) catch |e| {
        panic(@errorReturnTrace(), "Failed to register keyboard IRQ: {}\n", .{e});
    };
    keyboard = try allocator.create(Keyboard);
    keyboard.* = Keyboard.init();
    return keyboard;
}

fn testResetGlobals() void {
    pressed_keys = 0;
    special_sequence = false;
    expected_releases = 0;
    on_print_screen = false;
}

test "parseScanCode" {
    testResetGlobals();

    // Test basic keys
    const basic_keys = &[_]?KeyPosition{
        KeyPosition.ESC,
        KeyPosition.ONE,
        KeyPosition.TWO,
        KeyPosition.THREE,
        KeyPosition.FOUR,
        KeyPosition.FIVE,
        KeyPosition.SIX,
        KeyPosition.SEVEN,
        KeyPosition.EIGHT,
        KeyPosition.NINE,
        KeyPosition.ZERO,
        KeyPosition.HYPHEN,
        KeyPosition.EQUALS,
        KeyPosition.BACKSPACE,
        KeyPosition.TAB,
        KeyPosition.Q,
        KeyPosition.W,
        KeyPosition.E,
        KeyPosition.R,
        KeyPosition.T,
        KeyPosition.Y,
        KeyPosition.U,
        KeyPosition.I,
        KeyPosition.O,
        KeyPosition.P,
        KeyPosition.LEFT_BRACKET,
        KeyPosition.RIGHT_BRACKET,
        KeyPosition.ENTER,
        KeyPosition.LEFT_CTRL,
        KeyPosition.A,
        KeyPosition.S,
        KeyPosition.D,
        KeyPosition.F,
        KeyPosition.G,
        KeyPosition.H,
        KeyPosition.J,
        KeyPosition.K,
        KeyPosition.L,
        KeyPosition.SEMICOLON,
        KeyPosition.APOSTROPHE,
        KeyPosition.BACKTICK,
        KeyPosition.LEFT_SHIFT,
        KeyPosition.HASH,
        KeyPosition.Z,
        KeyPosition.X,
        KeyPosition.C,
        KeyPosition.V,
        KeyPosition.B,
        KeyPosition.N,
        KeyPosition.M,
        KeyPosition.COMMA,
        KeyPosition.DOT,
        KeyPosition.FORWARD_SLASH,
        KeyPosition.RIGHT_SHIFT,
        KeyPosition.KEYPAD_ASTERISK,
        KeyPosition.LEFT_ALT,
        KeyPosition.SPACE,
        KeyPosition.CAPS_LOCK,
        KeyPosition.F1,
        KeyPosition.F2,
        KeyPosition.F3,
        KeyPosition.F4,
        KeyPosition.F5,
        KeyPosition.F6,
        KeyPosition.F7,
        KeyPosition.F8,
        KeyPosition.F9,
        KeyPosition.F10,
        KeyPosition.NUM_LOCK,
        KeyPosition.SCROLL_LOCK,
        KeyPosition.KEYPAD_7,
        KeyPosition.KEYPAD_8,
        KeyPosition.KEYPAD_9,
        KeyPosition.KEYPAD_MINUS,
        KeyPosition.KEYPAD_4,
        KeyPosition.KEYPAD_5,
        KeyPosition.KEYPAD_6,
        KeyPosition.KEYPAD_PLUS,
        KeyPosition.KEYPAD_1,
        KeyPosition.KEYPAD_2,
        KeyPosition.KEYPAD_3,
        KeyPosition.KEYPAD_0,
        KeyPosition.KEYPAD_DOT,
        null,
        null,
        KeyPosition.BACKSLASH,
        KeyPosition.F11,
        KeyPosition.F12,
    };
    comptime var scan_code = 1;
    inline for (basic_keys) |key| {
        var res = parseScanCode(scan_code);
        if (key) |k| {
            const r = res orelse unreachable;
            testing.expectEqual(k, r.position);
            testing.expectEqual(false, r.released);
            testing.expectEqual(pressed_keys, 1);
        }
        testing.expectEqual(on_print_screen, false);
        testing.expectEqual(special_sequence, false);
        testing.expectEqual(expected_releases, 0);
        // Test release scan code for key
        if (key) |k| {
            res = parseScanCode(scan_code | 128);
            const r = res orelse unreachable;
            testing.expectEqual(k, r.position);
            testing.expectEqual(true, r.released);
            testing.expectEqual(pressed_keys, 0);
            testing.expectEqual(on_print_screen, false);
            testing.expectEqual(special_sequence, false);
            testing.expectEqual(expected_releases, 0);
        }
        scan_code += 1;
    }

    // Test the special keys
    // 'simple' sepcial keys consist of one release byte, a key then an extra release byte
    const simple_special_keys = &[_]?KeyPosition{
        KeyPosition.UP_ARROW,
        KeyPosition.LEFT_ARROW,
        KeyPosition.RIGHT_ARROW,
        KeyPosition.DOWN_ARROW,
        KeyPosition.INSERT,
        KeyPosition.HOME,
        KeyPosition.PAGE_UP,
        KeyPosition.DELETE,
        KeyPosition.END,
        KeyPosition.PAGE_DOWN,
        KeyPosition.KEYPAD_SLASH,
        KeyPosition.KEYPAD_ENTER,
        KeyPosition.RIGHT_ALT,
        KeyPosition.SPECIAL,
    };
    const simple_special_codes = &[_]u8{ 72, 75, 77, 80, 82, 71, 73, 83, 79, 81, 53, 28, 56, 91 };
    for (simple_special_keys) |key, i| {
        testing.expectEqual(parseScanCode(128), null);
        testing.expectEqual(pressed_keys, 0);
        testing.expectEqual(on_print_screen, false);
        testing.expectEqual(special_sequence, true);
        testing.expectEqual(expected_releases, 0);

        var res = parseScanCode(simple_special_codes[i]) orelse unreachable;
        testing.expectEqual(false, res.released);
        testing.expectEqual(key, res.position);
        testing.expectEqual(pressed_keys, 1);
        testing.expectEqual(on_print_screen, false);
        testing.expectEqual(special_sequence, true);
        testing.expectEqual(expected_releases, 1);

        testing.expectEqual(parseScanCode(128), null);
        testing.expectEqual(pressed_keys, 1);
        testing.expectEqual(on_print_screen, false);
        testing.expectEqual(special_sequence, true);
        testing.expectEqual(expected_releases, 0);

        res = parseScanCode(simple_special_codes[i] | 128) orelse unreachable;
        testing.expectEqual(true, res.released);
        testing.expectEqual(key, res.position);
        testing.expectEqual(pressed_keys, 0);
        testing.expectEqual(on_print_screen, false);
        testing.expectEqual(special_sequence, false);
        testing.expectEqual(expected_releases, 0);
    }
}
