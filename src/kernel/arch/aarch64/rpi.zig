const arch = @import("arch.zig");
const mmio = @import("mmio.zig");

/// The supported aarch64-capable raspberry pi boards
pub const RaspberryPiBoard = enum {
    RaspberryPi3,
    RaspberryPi4,

    pub fn fromPartNumber(part_num: u12) ?RaspberryPiBoard {
        return switch (part_num) {
            0xD03 => RaspberryPiBoard.RaspberryPi3,
            0xD08 => RaspberryPiBoard.RaspberryPi4,
            else => null,
        };
    }

    pub fn mmioAddress(self: @This()) usize {
        return switch (self) {
            .RaspberryPi3 => 0x3F000000,
            .RaspberryPi4 => 0xFE000000,
        };
    }

    pub fn memoryKB(self: @This()) usize {
        return switch (self) {
            // TODO: Detect the amount of memory on the RPi4
            .RaspberryPi3, .RaspberryPi4 => 1 * 1024 * 1024,
        };
    }
};

/// Spin the cpu while flashing the led
///
/// IN: flashing period in number of loops
///
/// Does not return
///
pub fn spinLed(period: u32) noreturn {
    const activity_led = 29;
    pinSetFunction(activity_led, .Output);
    var i: u32 = 0;
    var j: u32 = 0;
    while (true) : (j += 1) {
        if (j % (period * 1000 / 2) == 0) {
            i += 1;
            pinWrite(activity_led, @truncate(u1, i));
        }
    }
}

/// Set the pin function
///
/// IN: pin_index is the bcm pin number
/// IN: function is the PinFunction, such as input, output, or internally routed (alternate)
///
pub fn pinSetFunction(pin_index: u6, function: PinFunction) void {
    mmio.readModifyWriteField(arch.mmio_addr, .GPIO_FSEL0, @enumToInt(function), pin_index);
}

/// Set the pin pull up/down
///
/// IN: pin_index is the bcm pin number
/// IN: pull is taken from PinPull, such as up, down, or none
///
pub fn pinSetPull(pin_index: u6, pull: PinPull) void {
    mmio.write(arch.mmio_addr, .GPIO_PULL, @enumToInt(pull));
    delay(150);
    mmio.writeClock(arch.mmio_addr, .GPIO_PULL_CLK0, @as(u1, 1), pin_index);
    delay(150);
}

/// Set both the pin function and pull up
///
/// IN: pin_index is the bcm pin number
/// IN: pull is taken from PinPull, such as up, down, or none
/// IN: function is the PinFunction, such as input, output, or internally routed (alternate)
///
pub fn pinSetPullUpAndFunction(pin_index: u6, pull: PinPull, function: PinFunction) void {
    pinSetPull(pin_index, pull);
    pinSetFunction(pin_index, function);
}

/// Write 0 or 1 to the selectged pin
///
/// IN: pin_index is the bcm pin number
/// IN: zero_or_one is the value written to the pin (0 or 1)
///
fn pinWrite(pin_index: u6, zero_or_one: u1) void {
    mmio.writeClock(arch.mmio_addr, if (zero_or_one == 0) mmio.Register.GPIO_CLR0 else .GPIO_SET0, @as(u1, 1), pin_index);
}

/// Available pin functions
const PinFunction = enum(u3) {
    /// The pin functions as an input
    Input = 0,
    /// The pin functions as an output
    Output = 1,
    /// The pin functions as an output using internal routing alternatice 0
    AlternateFunction0 = 4,
    /// The pin functions as an output using internal routing alternatice 1
    AlternateFunction1 = 5,
    /// The pin functions as an output using internal routing alternatice 2
    AlternateFunction2 = 6,
    /// The pin functions as an output using internal routing alternatice 3
    AlternateFunction3 = 7,
    /// The pin functions as an output using internal routing alternatice 4
    AlternateFunction4 = 3,
    /// The pin functions as an output using internal routing alternatice 5
    AlternateFunction5 = 2,
};

/// Available pin pull/up down states
const PinPull = enum {
    None,
    Down,
    Up,
};

/// Delay for a fixed amount of time
///
/// IN: count in cpu cycles
///
fn delay(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        asm volatile ("mov x0, x0");
    }
}
