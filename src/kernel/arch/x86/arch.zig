// Zig version: 0.4.0

const is_test = @import("builtin").is_test;

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
pub fn outb(port: u16, data: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [port] "{dx}" (port),
          [data] "{al}" (data)
    );
}

///
/// Inline assembly that reads data from a given port and returns its value.
///
/// Arguments:
///     IN port: u16 - The port to read data from.
///
/// Return:
///     The data that the port returns.
///
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8)
        : [port] "N{dx}" (port)
    );
}

///
/// A simple way of waiting for I/O event to happen by doing an I/O event to flush the I/O
/// event being waited.
///
pub fn ioWait() void {
    outb(0x80, 0);
}
