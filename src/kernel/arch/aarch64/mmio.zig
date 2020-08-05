const log = @import("../../log.zig");
const std = @import("std");

const MMIO_OFFSET: usize = 0x200000;
const GPIO_OFFSET: usize = MMIO_OFFSET + 0x0000;
const UART_OFFSET: usize = MMIO_OFFSET + 0x1000;
const AUX_OFFSET: usize = MMIO_OFFSET + 0x15000;
const MBOX_OFFSET: usize = 0xB880;

pub const Register = enum(usize) {
    AUX_IRQ = AUX_OFFSET + 0x00,
    AUX_ENABLES = AUX_OFFSET + 0x04,
    AUX_MU_IO_REG = AUX_OFFSET + 0x40,
    AUX_MU_IER_REG = AUX_OFFSET + 0x44,
    AUX_MU_IIR_REG = AUX_OFFSET + 0x48,
    AUX_MU_LCR_REG = AUX_OFFSET + 0x4c,
    AUX_MU_MCR_REG = AUX_OFFSET + 0x50,
    AUX_MU_LSR_REG = AUX_OFFSET + 0x54,
    AUX_MU_MSR_REG = AUX_OFFSET + 0x58,
    AUX_MU_SCRATCH = AUX_OFFSET + 0x5c,
    AUX_MU_CNTL_REG = AUX_OFFSET + 0x60,
    AUX_MU_STAT_REG = AUX_OFFSET + 0x64,
    AUX_MU_BAUD_REG = AUX_OFFSET + 0x68,
    GPIO_FSEL0 = GPIO_OFFSET + 0x00,
    GPIO_FSEL1 = GPIO_OFFSET + 0x04,
    GPIO_FSEL2 = GPIO_OFFSET + 0x08,
    GPIO_FSEL3 = GPIO_OFFSET + 0x0c,
    GPIO_FSEL4 = GPIO_OFFSET + 0x10,
    GPIO_FSEL5 = GPIO_OFFSET + 0x14,
    GPIO_SET0 = GPIO_OFFSET + 0x1c,
    GPIO_SET1 = GPIO_OFFSET + 0x20,
    GPIO_CLR0 = GPIO_OFFSET + 0x28,
    GPIO_CLR1 = GPIO_OFFSET + 0x2c,
    GPIO_PULL = GPIO_OFFSET + 0x94,
    GPIO_PULL_CLK0 = GPIO_OFFSET + 0x98,
    GPIO_PULL_CLK1 = GPIO_OFFSET + 0x9c,
    MBOX_STATUS = MBOX_OFFSET + 0x18,
    MBOX_WRITE = MBOX_OFFSET + 0x20,
    MBOX_READ = MBOX_OFFSET + 0x00,
    UART_DATA = UART_OFFSET + 0x00,
    UART_FLAGS = UART_OFFSET + 0x18,
    UART_CONTROL = UART_OFFSET + 0x30,
    UART_INT_CONTROL = UART_OFFSET + 0x44,
    UART_BAUD_INT = UART_OFFSET + 0x24,
    UART_BAUD_FRAC = UART_OFFSET + 0x28,
    UART_LINE_CONTROL = UART_OFFSET + 0x2C,
    UART_INT_MASK = UART_OFFSET + 0x38,
};

pub fn write(mmio_base: usize, reg: Register, data: u32) void {
    const addr = mmio_base + @enumToInt(reg);
    const ptr = @intToPtr(*volatile u32, addr);
    ptr.* = data;
}

pub fn read(mmio_base: usize, reg: Register) u32 {
    const addr = mmio_base + @enumToInt(reg);
    const ptr = @intToPtr(*volatile u32, addr);
    return ptr.*;
}

const GPIO_MAX_PIN = 53;

pub const RegisterBitField = struct {
    register: Register,
    shifted_mask: u32,
    shifted_data: u32,

    pub fn at(f: *RegisterBitField, mmio_base: usize, first_register: Register, data: anytype, field_index: usize) void {
        const field_width = @bitSizeOf(@TypeOf(data));
        const fields_per_register: usize = 32 / field_width;
        const mask = (@as(u32, 1) << field_width) - 1;
        const shift_count = @truncate(u5, ((field_index % fields_per_register) * field_width));
        f.register = @intToEnum(Register, @enumToInt(first_register) + field_index / fields_per_register * 4);
        f.shifted_mask = mask << shift_count;
        f.shifted_data = @as(u32, data) << shift_count;
    }
};

pub fn writeClock(mmio_base: usize, first_register: Register, data: anytype, field_index: usize) void {
    var field: RegisterBitField = undefined;
    field.at(mmio_base, first_register, data, field_index);
    write(mmio_base, field.register, field.shifted_data);
}

pub fn readModifyWriteField(mmio_base: usize, first_register: Register, data: anytype, field_index: usize) void {
    var field: RegisterBitField = undefined;
    field.at(mmio_base, first_register, data, field_index);
    var modified = read(mmio_base, field.register);
    modified &= ~field.shifted_mask;
    modified |= field.shifted_data;
    write(mmio_base, field.register, modified);
}
