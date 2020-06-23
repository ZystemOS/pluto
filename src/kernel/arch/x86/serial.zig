const arch = @import("arch.zig");
const panic = @import("../../panic.zig").panic;
const testing = @import("std").testing;

/// The I/O port numbers associated with each serial port
pub const Port = enum(u16) {
    COM1 = 0x3F8,
    COM2 = 0x2F8,
    COM3 = 0x3E8,
    COM4 = 0x2E8,
};

/// Errors thrown by serial functions
pub const SerialError = error{
    /// The given baudrate is outside of the allowed range
    InvalidBaudRate,

    /// The given char len is outside the allowed range.
    InvalidCharacterLength,
};

/// The LCR is the line control register
const LCR: u16 = 3;

/// Maximum baudrate
const BAUD_MAX: u32 = 115200;

/// 8 bits per serial character
const CHAR_LEN: u8 = 8;

/// One stop bit per transmission
const SINGLE_STOP_BIT: bool = true;

/// No parity bit
const PARITY_BIT: bool = false;

/// Default baudrate
pub const DEFAULT_BAUDRATE = 38400;

///
/// Compute a value that encodes the serial properties
/// Used by the line control register
///
/// Arguments:
///     IN char_len: u8 - The number of bits in each individual byte. Must be 0 or between 5 and 8 (inclusive).
///     IN stop_bit: bool - If a stop bit should included in each transmission.
///     IN parity_bit: bool - If a parity bit should be included in each transmission.
///     IN msb: u1 - The most significant bit to use.
///
/// Return: u8
///     The computed lcr value.
///
/// Error: SerialError
///     InvalidCharacterLength - If the char_len is less than 5 or greater than 8.
///
fn lcrValue(char_len: u8, stop_bit: bool, parity_bit: bool, msb: u1) SerialError!u8 {
    if (char_len != 0 and (char_len < 5 or char_len > 8))
        return SerialError.InvalidCharacterLength;
    // Set the msb and OR in all arguments passed
    const val = char_len & 0x3 |
        @intCast(u8, @boolToInt(stop_bit)) << 2 |
        @intCast(u8, @boolToInt(parity_bit)) << 3 |
        @intCast(u8, msb) << 7;
    return val;
}

///
/// The serial controller accepts a divisor rather than a raw baudrate, as that is more space efficient.
/// This function computes the divisor for a desired baudrate. Note that multiple baudrates can have the same divisor.
///
/// Arguments:
///     baud: u32 - The desired baudrate. Must be greater than 0 and less than BAUD_MAX.
///
/// Return: u16
///     The computed divisor.
///
/// Error: SerialError
///     InvalidBaudRate - If baudrate is 0 or greater than BAUD_MAX.
///
fn baudDivisor(baud: u32) SerialError!u16 {
    if (baud > BAUD_MAX or baud == 0)
        return SerialError.InvalidBaudRate;
    return @truncate(u16, BAUD_MAX / baud);
}

///
/// Checks if the transmission buffer is empty, which means data can be sent.
///
/// Arguments:
///     port: Port - The port to check.
///
/// Return: bool
///     If the transmission buffer is empty.
///
fn transmitIsEmpty(port: Port) bool {
    return arch.inb(@enumToInt(port) + 5) & 0x20 > 0;
}

///
/// Write a byte to a serial port. Waits until the transmission queue is empty.
///
/// Arguments:
///     char: u8 - The byte to send.
///     port: Port - The port to send the byte to.
///
pub fn write(char: u8, port: Port) void {
    while (!transmitIsEmpty(port)) {
        arch.halt();
    }
    arch.outb(@enumToInt(port), char);
}

///
/// Initialise a serial port to a certain baudrate
///
/// Arguments
///  IN baud: u32 - The baudrate to use. Cannot be more than MAX_BAUDRATE
///  IN port: Port - The port to initialise
///
/// Error: SerialError
///     InvalidBaudRate - The baudrate is 0 or greater than BAUD_MAX.
///
pub fn init(baud: u32, port: Port) SerialError!void {
    // The baudrate is sent as a divisor of the max baud rate
    const divisor: u16 = try baudDivisor(baud);
    const port_int = @enumToInt(port);
    // Send a byte to start setting the baudrate
    arch.outb(port_int + LCR, lcrValue(0, false, false, 1) catch |e| {
        panic(@errorReturnTrace(), "Failed to initialise serial output setup: {}", .{e});
    });
    // Send the divisor's lsb
    arch.outb(port_int, @truncate(u8, divisor));
    // Send the divisor's msb
    arch.outb(port_int + 1, @truncate(u8, divisor >> 8));
    // Send the properties to use
    arch.outb(port_int + LCR, lcrValue(CHAR_LEN, SINGLE_STOP_BIT, PARITY_BIT, 0) catch |e| {
        panic(@errorReturnTrace(), "Failed to setup serial properties: {}", .{e});
    });
    // Stop initialisation
    arch.outb(port_int + 1, 0);
}

test "lcrValue computes the correct value" {
    // Check valid combinations
    inline for ([_]u8{ 0, 5, 6, 7, 8 }) |char_len| {
        inline for ([_]bool{ true, false }) |stop_bit| {
            inline for ([_]bool{ true, false }) |parity_bit| {
                inline for ([_]u1{ 0, 1 }) |msb| {
                    const val = try lcrValue(char_len, stop_bit, parity_bit, msb);
                    const expected = char_len & 0x3 |
                        @boolToInt(stop_bit) << 2 |
                        @boolToInt(parity_bit) << 3 |
                        @intCast(u8, msb) << 7;
                    testing.expectEqual(val, expected);
                }
            }
        }
    }

    // Check invalid char lengths
    testing.expectError(SerialError.InvalidCharacterLength, lcrValue(4, false, false, 0));
    testing.expectError(SerialError.InvalidCharacterLength, lcrValue(9, false, false, 0));
}

test "baudDivisor" {
    // Check invalid baudrates
    inline for ([_]u32{ 0, BAUD_MAX + 1 }) |baud| {
        testing.expectError(SerialError.InvalidBaudRate, baudDivisor(baud));
    }

    // Check valid baudrates
    var baud: u32 = 1;
    while (baud <= BAUD_MAX) : (baud += 1) {
        const val = try baudDivisor(baud);
        const expected = @truncate(u16, BAUD_MAX / baud);
        testing.expectEqual(val, expected);
    }
}
