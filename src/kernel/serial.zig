const arch = @import("arch.zig").internals;
const build_options = @import("build_options");

pub const Serial = struct {
    /// Function that writes a single byte to the serial stream
    pub const Write = fn (byte: u8) void;

    write: Write,

    ///
    /// Write a slice of bytes to the serial stream.
    ///
    /// Arguments:
    ///     str: []const u8 - The bytes to send.
    ///
    pub fn writeBytes(self: *const @This(), bytes: []const u8) void {
        for (bytes) |byte| {
            self.write(byte);
        }
    }
};

///
/// Initialise the serial interface. The details of how this is done depends on the architecture.
///
/// Arguments:
///     IN boot_payload: arch.BootPayload - The payload passed to the kernel at boot. How this is used depends on the architecture
///
/// Return: Serial
///     The serial interface constructed by the architecture
///
pub fn init(boot_payload: arch.BootPayload) Serial {
    const serial = arch.initSerial(boot_payload);
    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(serial),
        else => {},
    }
    return serial;
}

///
/// Run all the runtime tests
///
pub fn runtimeTests(serial: Serial) void {
    rt_writeByte(serial);
    rt_writeBytes(serial);
}

///
/// Test writing a byte and a new line separately
///
fn rt_writeByte(serial: Serial) void {
    serial.write('c');
    serial.write('\n');
}

///
/// Test writing a series of bytes
///
fn rt_writeBytes(serial: Serial) void {
    serial.writeBytes(&[_]u8{ '1', '2', '3', '\n' });
}
