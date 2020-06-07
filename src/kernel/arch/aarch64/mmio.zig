const GPIO_OFFSET: usize = 0x200000;
const UART_OFFSET: usize = GPIO_OFFSET + 0x1000;

pub const Register = enum(usize) {
    UART_DATA = UART_OFFSET + 0x00,
    UART_FLAGS = UART_OFFSET + 0x18,
    UART_CONTROL = UART_OFFSET + 0x30,
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
