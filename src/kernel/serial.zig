const arch = @import("arch.zig").internals;

// The LCR is the line control register
const LCR = 3;
// Maximum baudrate
const BAUD_MAX = 115200;
// 8 bits per serial character
const CHAR_LEN = 8;
// One stop bit per transmission
const SINGLE_STOP_BIT = true;
// No parity bit
const PARITY_BIT = false;

pub const DEFAULT_BAUDRATE = 38400;

const SerialError = error{InvalidBaud};

pub const Port = enum(u16) {
    COM1 = 0x3F8,
    COM2 = 0x2F8,
    COM3 = 0x3E8,
    COM4 = 0x2E8,
};

// Compute a value that encodes the serial properties
// This is fed into the LCR (line control register)
fn lcrValue(char_len: u8, comptime stop_bit: bool, comptime parity_bit: bool, msb: u8) u8 {
    var val = char_len & 0x3;
    val |= (if (stop_bit) 0 else 1) << 2;
    val |= (if (parity_bit) 1 else 0) << 3;
    val |= (msb & 0x1) << 7;
    return val;
}

fn baudDivisor(baud: u32) SerialError!u16 {
    if (baud > BAUD_MAX or baud <= 0) return SerialError.InvalidBaud;
    return @intCast(u16, BAUD_MAX / baud);
}

fn transmitIsEmpty(port: Port) bool {
    return arch.inb(@enumToInt(port) + 5) & 0x20 > 0;
}

///
/// Initialise a serial port to a certain baudrate
///
/// Arguments
///  IN baud: u32 - The baudrate to use. Cannot be more than MAX_BAUDRATE
///  IN port: Port - The port to initialise
///
/// Throws a SerialError if the baudrate is invalid
///
pub fn init(baud: u32, port: Port) SerialError!void {
    // The baudrate is sent as a divisor of the max baud rate
    const divisor: u16 = try baudDivisor(baud);
    const port_int = @enumToInt(port);
    // Send a byte to start setting the baudrate
    arch.outb(port_int + LCR, lcrValue(0, false, false, 1));
    // Send the divisor's lsb
    arch.outb(port_int, @truncate(u8, divisor));
    // Send the divisor's msb
    arch.outb(port_int + 1, @truncate(u8, divisor >> 8));
    // Send the properties to use
    arch.outb(port_int + LCR, lcrValue(CHAR_LEN, SINGLE_STOP_BIT, PARITY_BIT, 0));
    // Stop initialisation
    arch.outb(port_int + 1, 0);
}

pub fn write(char: u8, port: Port) void {
    while (!transmitIsEmpty(port)) {
        arch.halt();
    }
    arch.outb(@enumToInt(port), char);
}

pub fn writeString(str: []const u8, port: Port) void {
    for (str) |char| {
        write(char, port);
    }
}
