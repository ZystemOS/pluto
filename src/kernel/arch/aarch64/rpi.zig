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

pub fn pinSetFunction(pin_index: u6, function: PinFunction) void {
    mmio.readModifyWriteField(arch.mmio_addr, .GPIO_FSEL0, @enumToInt(function), pin_index);
}

pub fn pinSetPull(pin_index: u6, pull: PinPull) void {
    mmio.write(arch.mmio_addr, .GPIO_PULL, @enumToInt(pull));
    delay(150);
    mmio.writeClock(arch.mmio_addr, .GPIO_PULL_CLK0, @as(u1, 1), pin_index);
    delay(150);
}

pub fn pinSetPullUpAndFunction(pin_index: u6, pull: PinPull, function: PinFunction) void {
    pinSetPull(pin_index, pull);
    pinSetFunction(pin_index, function);
}

fn pinWrite(pin_index: u6, zero_or_one: u1) void {
    mmio.writeClock(arch.mmio_addr, if (zero_or_one == 0) mmio.Register.GPIO_CLR0 else .GPIO_SET0, @as(u1, 1), pin_index);
}

const PinFunction = enum(u3) {
    Input = 0,
    Output = 1,
    AlternateFunction0 = 4,
    AlternateFunction1 = 5,
    AlternateFunction2 = 6,
    AlternateFunction3 = 7,
    AlternateFunction4 = 3,
    AlternateFunction5 = 2,
};

const PinPull = enum {
    None,
    Down,
    Up,
};

fn delay(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        asm volatile ("mov x0, x0");
    }
}
