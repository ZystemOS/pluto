const std = @import("std");
const vmm = @import("../../vmm.zig");
const mem = @import("../../mem.zig");
const Serial = @import("../../serial.zig").Serial;
const log = @import("../../log.zig");
const rpi = @import("rpi.zig");
const mmio = @import("mmio.zig");
/// The type of the payload passed to a virtual memory mapper.
// TODO: implement
pub const VmmPayload = usize;
pub const BootPayload = *const rpi.RaspberryPiBoard;

// TODO: implement
pub const MEMORY_BLOCK_SIZE: usize = 4 * 1024;

// TODO: implement
pub const VMM_MAPPER: vmm.Mapper(VmmPayload) = vmm.Mapper(VmmPayload){ .mapFn = undefined, .unmapFn = undefined };

// TODO: implement
pub const KERNEL_VMM_PAYLOAD: VmmPayload = 0;

// The system clock frequency in Hz
const SYSTEM_CLOCK: usize = 700000000;
const UART_BAUD_RATE: usize = 115200;

var mmio_addr: usize = undefined;

pub fn initSerial(board: BootPayload) Serial {
    mmio_addr = board.mmioAddress();
    // Disable uart
    mmio.write(mmio_addr, mmio.Register.UART_CONTROL, 0);
    // Disable pull up/down for all GPIO pins
    mmio.write(mmio_addr, mmio.Register.GPIO_PULL, 0);
    // Disable pull up/down for pins 14 and 15
    mmio.write(mmio_addr, mmio.Register.GPIO_PULL_CLK, (1 << 14) | (1 << 15));
    // Apply pull up/down change for pins 14 and 15
    mmio.write(mmio_addr, mmio.Register.GPIO_PULL_CLK, 0);
    // Clear pending uart interrupts
    mmio.write(mmio_addr, mmio.Register.UART_INT_CONTROL, 0x7FF);

    // For models after rpi 2 (those supporting aarch64) the uart clock is dependent on the system clock
    // so set it to a known constant rather than calculating it
    const cmd: []const volatile u32 align(16) = &[_]u32{ 36, 0, 0x38002, 12, 8, 2, SYSTEM_CLOCK, 0, 0 };
    const cmd_addr = (@intCast(u32, @ptrToInt(&cmd)) & ~@as(u32, 0xF)) | 8;
    // Wait until the mailbox isn't busy
    while ((mmio.read(mmio_addr, mmio.Register.MBOX_STATUS) & 0x80000000) != 0) {}
    mmio.write(mmio_addr, mmio.Register.MBOX_WRITE, cmd_addr);
    // Wait for the correct response
    while ((mmio.read(mmio_addr, mmio.Register.MBOX_STATUS) & 0x40000000) != 0 or mmio.read(mmio_addr, mmio.Register.MBOX_READ) != cmd_addr) {}

    // Setup baudrate
    const divisor: f32 = @intToFloat(f32, SYSTEM_CLOCK) / @intToFloat(f32, 16 * UART_BAUD_RATE);
    const divisor_int: u32 = @floatToInt(u32, divisor);
    const divisor_frac: u32 = @floatToInt(u32, (divisor - @intToFloat(f32, divisor_int)) * 64.0 + 0.5);
    mmio.write(mmio_addr, mmio.Register.UART_BAUD_INT, divisor_int);
    mmio.write(mmio_addr, mmio.Register.UART_BAUD_FRAC, divisor_frac);

    // Enable FIFO, 8 bit words, 1 stop bit and no parity bit
    mmio.write(mmio_addr, mmio.Register.UART_LINE_CONTROL, 1 << 4 | 1 << 5 | 1 << 6);
    // Mask all interrupts
    mmio.write(mmio_addr, mmio.Register.UART_INT_MASK, 1 << 1 | 1 << 4 | 1 << 5 | 1 << 6 | 1 << 7 | 1 << 8 | 1 << 9 | 1 << 10);
    // Enable UART0 receive and transmit
    mmio.write(mmio_addr, mmio.Register.UART_CONTROL, 1 << 0 | 1 << 8 | 1 << 9);

    return .{
        .write = uartWriteByte,
    };
}

fn uartWriteByte(byte: u8) void {
    // Wait until the UART is ready to transmit
    while ((mmio.read(mmio_addr, mmio.Register.UART_FLAGS) & (1 << 5)) != 0) {}
    mmio.write(mmio_addr, mmio.Register.UART_DATA, byte);
}

pub fn initMem(payload: BootPayload) std.mem.Allocator.Error!mem.MemProfile {
    log.logInfo("Init mem\n", .{});
    defer log.logInfo("Done mem\n", .{});
    // TODO: implement
    mem.ADDR_OFFSET = 0;
    return mem.MemProfile{ .vaddr_end = @intToPtr([*]u8, 0x12345678), .vaddr_start = @intToPtr([*]u8, 0x12345678), .physaddr_start = @intToPtr([*]u8, 0x12345678), .physaddr_end = @intToPtr([*]u8, 0x12345678), .mem_kb = 0, .modules = &[_]mem.Module{}, .virtual_reserved = &[_]mem.Map{}, .physical_reserved = &[_]mem.Range{}, .fixed_allocator = undefined };
}

// TODO: implement
pub fn init(payload: BootPayload, mem_profile: *const mem.MemProfile, allocator: *std.mem.Allocator) void {}

// TODO: implement
pub fn inb(port: u32) u8 {
    return 0;
}

// TODO: implement
pub fn outb(port: u32, byte: u8) void {}

// TODO: implement
pub fn halt() noreturn {
    while (true) {}
}

// TODO: implement
pub fn haltNoInterrupts() noreturn {
    while (true) {}
}

// TODO: implement
pub fn spinWait() noreturn {
    while (true) {}
}
