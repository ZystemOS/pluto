// Zig version: 0.4.0

///
/// Initialise the architecture
///
pub fn init() void {}

///
/// Inline assembly to write to a given port with a byte of data.
///
/// Arguments:
///     IN port: u16 - The port to write to.
///     IN data: u8  - The byte of data that will be sent.
///
pub fn outb(port: u16, data: u8) void {}

///
/// Inline assembly that reads data from a given port and returns its value.
///
/// Arguments:
///     IN port: u16 - The port to read data from.
///
/// Return:
///     The data that the port returns.
///
pub fn inb(port: u16) u8 {return 0;}

///
/// A simple way of waiting for I/O event to happen by doing an I/O event to flush the I/O
/// event being waited.
///
pub fn ioWait() void {}
