const GPIO_OFFSET: usize = 0x200000;
const UART_OFFSET: usize = GPIO_OFFSET + 0x1000;
const MBOX_OFFSET: usize = 0xB880;

pub const Register = enum(usize) {
    GPIO_PULL = GPIO_OFFSET + 0x94,
    GPIO_PULL_CLK = GPIO_OFFSET + 0x98,
    UART_DATA = UART_OFFSET + 0x00,
    UART_FLAGS = UART_OFFSET + 0x18,
    UART_CONTROL = UART_OFFSET + 0x30,
    UART_INT_CONTROL = UART_OFFSET + 0x44,
    UART_BAUD_INT = UART_OFFSET + 0x24,
    UART_BAUD_FRAC = UART_OFFSET + 0x28,
    UART_LINE_CONTROL = UART_OFFSET + 0x2C,
    UART_INT_MASK = UART_OFFSET + 0x38,
    MBOX_STATUS = MBOX_OFFSET + 0x18,
    MBOX_WRITE = MBOX_OFFSET + 0x20,
    MBOX_READ = MBOX_OFFSET + 0x00,
};

pub fn write(mmio_base: usize, reg: Register, data: u32) void {
    const addr = mmio_base + @enumToInt(reg);
    const ptr = @intToPtr(*u32, addr);
    ptr.* = data;
}

pub fn read(mmio_base: usize, reg: Register) u32 {
    const addr = mmio_base + @enumToInt(reg);
    const ptr = @intToPtr(*u32, addr);
    return ptr.*;
}
