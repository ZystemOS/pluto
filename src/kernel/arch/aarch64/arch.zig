const std = @import("std");
const vmm = @import("../../vmm.zig");
const mem = @import("../../mem.zig");
const Serial = @import("../../serial.zig").Serial;
const TTY = @import("../../tty.zig").TTY;
const interrupts = @import("interrupts.zig");
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

pub var is_qemu: bool = undefined;
var mmio_addr: usize = undefined;

extern var KERNEL_PHYSADDR_START: *u32;
extern var KERNEL_PHYSADDR_END: *u32;

pub fn initTTY(boot_payload: BootPayload) TTY {
    return undefined;
}

pub fn initSerial(board: BootPayload) Serial {
    mmio_addr = board.mmioAddress();
    is_qemu = interrupts.mrs("cntfrq_el0") != 0;
    if (!is_qemu) {
        pinSetFunction(14, .AlternateFunction5);
        pinSetPull(14, .None);
        pinSetFunction(15, .AlternateFunction5);
        pinSetPull(15, .None);
        mmio.write(mmio_addr, .AUX_ENABLES, 1);
        mmio.write(mmio_addr, .AUX_MU_IER_REG, 0);
        mmio.write(mmio_addr, .AUX_MU_CNTL_REG, 0);
        mmio.write(mmio_addr, .AUX_MU_LCR_REG, 3);
        mmio.write(mmio_addr, .AUX_MU_MCR_REG, 0);
        mmio.write(mmio_addr, .AUX_MU_IER_REG, 0);
        mmio.write(mmio_addr, .AUX_MU_IIR_REG, 0xc6);
        mmio.write(mmio_addr, .AUX_MU_BAUD_REG, 270);
        mmio.write(mmio_addr, .AUX_MU_CNTL_REG, 3);
    }
    return .{
        .write = uartWriteByte,
    };
}

pub fn uartWriteByte(byte: u8) void {
    if (byte == 10) {
        uartWriteByte(13);
    }
    if (is_qemu) {
        while (mmio.read(mmio_addr, .UART_FR) & (1 << 5) != 0) {}
        mmio.write(mmio_addr, .UART_DR, byte);
    } else {
        while (mmio.read(mmio_addr, .AUX_MU_LSR_REG) & (1 << 5) == 0) {}
        mmio.write(mmio_addr, .AUX_MU_IO_REG, byte);
    }
}

pub fn initMem(payload: BootPayload) std.mem.Allocator.Error!mem.MemProfile {
    log.logInfo("Init mem\n", .{});
    defer log.logInfo("Done mem\n", .{});
    mem.ADDR_OFFSET = 0;
    const phys_start = @ptrCast([*]u8, &KERNEL_PHYSADDR_START);
    const phys_end = @ptrCast([*]u8, &KERNEL_PHYSADDR_END);
    const virt_start = phys_start;
    const virt_end = phys_end;
    var allocator = std.heap.FixedBufferAllocator.init(virt_end[0..mem.FIXED_ALLOC_SIZE]);

    var allocator_region = mem.Map{ .virtual = .{ .start = @ptrToInt(virt_end), .end = @ptrToInt(virt_end) + mem.FIXED_ALLOC_SIZE }, .physical = null };
    allocator_region.physical = .{ .start = mem.virtToPhys(allocator_region.virtual.start), .end = mem.virtToPhys(allocator_region.virtual.end) };

    return mem.MemProfile{ .vaddr_end = virt_end, .vaddr_start = virt_start, .physaddr_start = phys_start, .physaddr_end = phys_end, .mem_kb = payload.memoryKB(), .modules = &[_]mem.Module{}, .virtual_reserved = &[_]mem.Map{allocator_region}, .physical_reserved = &[_]mem.Range{}, .fixed_allocator = allocator };
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
    spinLed(500);
}

pub inline fn turnOnLed() void {
    asm volatile (
        \\ mov x0, #0x3f200000
        \\ ldr w1, [x0, #0x08]
        \\ mov x2, #0x38000000
        \\ bic x1, x1, x2
        \\ mov x2, #0x08000000
        \\ orr x1, x1, x2
        \\ str w1, [x0, #0x08]
        \\ mov x1, #0x20000000
        \\ str w1, [x0, #0x1c]
        :
        :
        : "x0", "x1", "x2"
    );
}

pub inline fn turnOffLed() void {
    asm volatile (
        \\ mov x0, #0x3f200000
        \\ ldr w1, [x0, #0x08]
        \\ mov x2, #0x38000000
        \\ bic x1, x1, x2
        \\ mov x2, #0x08000000
        \\ orr x1, x1, x2
        \\ str w1, [x0, #0x08]
        \\ mov x1, #0x20000000
        \\ str w1, [x0, #0x28]
        :
        :
        : "x0", "x1", "x2"
    );
}

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

fn pinSetFunction(pin_index: u6, f: PinFunction) void {
    mmio.readModifyWriteField(mmio_addr, .GPIO_FSEL0, @enumToInt(f), pin_index);
}

fn pinSetPull(pin_index: u6, pull: PinPull) void {
    mmio.write(mmio_addr, .GPIO_PUD, @enumToInt(pull));
    delay(150);
    mmio.writeClock(mmio_addr, .GPIO_PUDCLK0, @as(u1, 1), pin_index);
    delay(150);
    mmio.writeClock(mmio_addr, .GPIO_PUDCLK0, @as(u1, 0), pin_index);
    mmio.write(mmio_addr, .GPIO_PUD, @enumToInt(PinPull.None));
}

fn pinWrite(pin_index: u6, zero_or_one: u1) void {
    mmio.writeClock(mmio_addr, if (zero_or_one == 0) mmio.Register.GPIO_CLR0 else .GPIO_SET0, @as(u1, 1), pin_index);
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

// map 1GB to ram except last 16MB to mmio
pub fn enableFlatMmu() void {
    const level_2_table = @intToPtr([*]usize, 0x50000)[0..2];
    level_2_table[0] = 0x60000 | 0x3;
    level_2_table[1] = 0x70000 | 0x3;
    const page_table = @intToPtr([*]usize, 0x60000)[0 .. 2 * 8 * 1024];
    const page_size = 64 * 1024;
    const start_of_mmio = page_table.len - (16 * 1024 * 1024 / page_size);
    var index: usize = 0;
    while (index < start_of_mmio) : (index += 1) {
        page_table[index] = index * page_size + 0x0703; // normal pte=3 attr index=0 inner shareable=3 af=1
    }
    while (index < page_table.len) : (index += 1) {
        page_table[index] = index * page_size + 0x0607; // device pte=3 attr index=1 outer shareable=2 af=1
    }

    asm volatile (
        \\ mov x3, #0x04ff
        \\ msr mair_el3, x3
        \\
        \\ mrs x3, tcr_el3
        \\ mov x2, #0x4022 // tcr_el3 t0sz 34 tg0 64k
        \\ orr x3, x3, x2
        \\ mov x2, #0x80800000
        \\ orr x3, x3, x2
        \\ msr tcr_el3, x3
        \\
        \\ mov x1, #0x50000
        \\ msr ttbr0_el3, x1
        \\ isb
        \\ mrs x0, sctlr_el3
        \\ orr x0, x0, #1
        \\ msr sctlr_el3, x0
        \\ isb
        :
        :
        : "x0", "x1", "x2", "x3"
    );
}
