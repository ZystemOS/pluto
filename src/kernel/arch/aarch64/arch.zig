const std = @import("std");
const vmm = @import("../../vmm.zig");
const mem = @import("../../mem.zig");
const Serial = @import("../../serial.zig").Serial;
const TTY = @import("../../tty.zig").TTY;
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
pub var mmio_addr: usize = undefined;

extern var KERNEL_PHYSADDR_START: *u32;
extern var KERNEL_PHYSADDR_END: *u32;

pub fn initTTY(boot_payload: BootPayload) TTY {
    return undefined;
}

pub fn initMmioAddress(board: *rpi.RaspberryPiBoard) void {
    mmio_addr = board.mmioAddress();
}

pub fn initSerial(board: BootPayload) Serial {
    is_qemu = Cpu.cntfrq_el0.read() != 0;
    if (!is_qemu) {
        rpi.pinSetPullUpAndFunction(14, .None, .AlternateFunction5);
        rpi.pinSetPullUpAndFunction(15, .None, .AlternateFunction5);
        // rpi.pinSetPull(14, .None);
        // rpi.pinSetFunction(14, .AlternateFunction5);
        // rpi.pinSetPull(15, .None);
        // rpi.pinSetFunction(15, .AlternateFunction5);
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
    // if ascii line feed then first send carriage return
    if (byte == 10) {
        uartWriteByte(13);
    }
    if (is_qemu) {
        while (mmio.read(mmio_addr, .UART_FLAGS) & (1 << 5) != 0) {}
        mmio.write(mmio_addr, .UART_DATA, byte);
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
    while (true) {}
}

pub const Cpu = struct {
    pub const cntfrq_el0 = systemRegister("cntfrq_el0");
    pub const CurrentEL = systemRegister("CurrentEL");
    pub const elr = systemRegisterPerExceptionLevel("elr");
    pub const esr = systemRegisterPerExceptionLevel("esr");
    pub const far = systemRegisterPerExceptionLevel("far");
    pub const lr = cpuRegister("lr");
    pub const mair = systemRegisterPerExceptionLevel("mair");
    pub const midr = systemRegisterPerExceptionLevel("midr");
    pub const mpidr = systemRegisterPerExceptionLevel("mpidr");
    pub const sctlr = systemRegisterPerExceptionLevel("sctlr");
    pub const sp = cpuRegister("sp");
    pub const spsr = systemRegisterPerExceptionLevel("spsr");
    pub const tcr = systemRegisterPerExceptionLevel("tcr");
    pub const ttbr0 = systemRegisterPerExceptionLevel("ttbr0");
    pub const vbar = systemRegisterPerExceptionLevel("vbar");

    fn cpuRegister(comptime register_name: []const u8) type {
        return struct {
            pub inline fn read() usize {
                const data = asm ("mov %[data], " ++ register_name
                    : [data] "=r" (-> usize)
                );
                return data;
            }
            pub inline fn write(data: usize) void {
                asm volatile ("mov " ++ register_name ++ ", %[data]"
                    :
                    : [data] "r" (data)
                );
            }
        };
    }
    fn systemRegisterPerExceptionLevel(comptime register_name: []const u8) type {
        return struct {
            pub inline fn el(exception_level: u2) type {
                const level_string = switch (exception_level) {
                    0 => "0",
                    1 => "1",
                    2 => "2",
                    3 => "3",
                };
                return systemRegister(register_name ++ "_el" ++ level_string);
            }
        };
    }
    fn systemRegister(comptime register_name: []const u8) type {
        return struct {
            pub inline fn read() usize {
                const word = asm ("mrs %[word], " ++ register_name
                    : [word] "=r" (-> usize)
                );
                return word;
            }
            pub inline fn bitSet(bits: usize) void {
                write(read() | bits);
            }
            pub inline fn write(data: usize) void {
                asm volatile ("msr " ++ register_name ++ ", %[data]"
                    :
                    : [data] "r" (data)
                );
            }
        };
    }
    pub inline fn isb() void {
        asm volatile (
            \\ isb
        );
    }
    pub inline fn wfe() void {
        asm volatile (
            \\ wfe
        );
    }
};

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
    Cpu.mair.el(3).write(0x04ff);
    Cpu.tcr.el(3).bitSet(0x80804022);
    Cpu.ttbr0.el(3).write(0x50000);
    Cpu.isb();
    Cpu.sctlr.el(3).bitSet(0x1);
    Cpu.isb();
}
