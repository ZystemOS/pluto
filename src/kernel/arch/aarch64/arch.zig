const assert = std.debug.assert;
const std = @import("std");
const vmm = @import("../../vmm.zig");
const mem = @import("../../mem.zig");
const Serial = @import("../../serial.zig").Serial;
const tty = @import("tty.zig");
const TTY = @import("../../tty.zig").TTY;
const rpi = @import("rpi.zig");
const mmio = @import("mmio.zig");
const log = std.log.scoped(.aarch64_arch);
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

pub var mmio_addr: usize = undefined;

extern var KERNEL_PHYSADDR_START: *u32;
extern var KERNEL_PHYSADDR_END: *u32;

pub fn initTTY(boot_payload: BootPayload) TTY {
    return tty.init(&mem.fixed_buffer_allocator.allocator, boot_payload);
}

pub fn initMmioAddress(board: *rpi.RaspberryPiBoard) void {
    mmio_addr = board.mmioAddress();
}

// The auxiliary uart (uart1) is the primary uart used for the console on pi3b and up.
//  The main uart (uart0) is used for the on-board bluetooth device on these boards.
//  See https://www.raspberrypi.org/documentation/configuration/uart.md
//  Note that config.txt contains enable_uart=1 which locks the core clock frequency
//   which is required for a stable baud rate on the auxiliary uart (uart1.)
//
// However, qemu does not implement uart1. Therefore on qemu we use uart0 for the text console.
//  Furthermore uart0 on qemu does not need any initialization.
//
pub fn initSerial(board: BootPayload) Serial {
    if (!Cpu.isQemu()) {
        // On an actual rpi, initialize uart1 to 115200 baud on pins 14 and 15:
        rpi.pinSetPullUpAndFunction(14, .None, .AlternateFunction5);
        rpi.pinSetPullUpAndFunction(15, .None, .AlternateFunction5);
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
    if (Cpu.isQemu()) {
        // Since qemu does not implement uart1, qemu uses uart0 for the console:
        while (mmio.read(mmio_addr, .UART_FLAGS) & (1 << 5) != 0) {}
        mmio.write(mmio_addr, .UART_DATA, byte);
    } else {
        // On an actual rpi, use uart1:
        while (mmio.read(mmio_addr, .AUX_MU_LSR_REG) & (1 << 5) == 0) {}
        mmio.write(mmio_addr, .AUX_MU_IO_REG, byte);
    }
}

pub fn initMem(payload: BootPayload) std.mem.Allocator.Error!mem.MemProfile {
    log.info("Init mem\n", .{});
    defer log.info("Done mem\n", .{});
    mem.ADDR_OFFSET = 0;
    const phys_start = @ptrCast([*]u8, &KERNEL_PHYSADDR_START);
    const phys_end = @ptrCast([*]u8, &KERNEL_PHYSADDR_END);
    const virt_start = phys_start;
    const virt_end = phys_end;
    var allocator = &mem.fixed_buffer_allocator.allocator;

    var allocator_region = mem.Map{ .virtual = .{ .start = @ptrToInt(virt_end), .end = @ptrToInt(virt_end) }, .physical = null };

    return mem.MemProfile{ .vaddr_end = virt_end, .vaddr_start = virt_start, .physaddr_start = phys_start, .physaddr_end = phys_end, .mem_kb = payload.memoryKB(), .modules = &[_]mem.Module{}, .virtual_reserved = &[_]mem.Map{}, .physical_reserved = &[_]mem.Range{}, .fixed_allocator = mem.fixed_buffer_allocator };
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
    pub const cntfrq = systemRegisterPerExceptionLevel(.JustLevelZero, "cntfrq");
    pub const cntfrq_el0 = cntfrq.el(0);
    pub const CurrentEL = systemRegister("CurrentEL");
    pub const elr = systemRegisterPerExceptionLevel(.LevelsOneThroughThree, "elr");
    pub const elr_el1 = elr.el(1);
    pub const elr_el2 = elr.el(2);
    pub const elr_el3 = elr.el(3);
    pub const esr = systemRegisterPerExceptionLevel(.LevelsOneThroughThree, "esr");
    pub const esr_el1 = esr.el(1);
    pub const esr_el2 = esr.el(2);
    pub const esr_el3 = esr.el(3);
    pub const far = systemRegisterPerExceptionLevel(.LevelsOneThroughThree, "far");
    pub const far_el1 = far.el(1);
    pub const far_el2 = far.el(2);
    pub const far_el3 = esr.el(3);
    pub const lr = cpuRegister("lr");
    pub const mair = systemRegisterPerExceptionLevel(.LevelsOneThroughThree, "mair");
    pub const mair_el1 = mair.el(1);
    pub const mair_el2 = mair.el(2);
    pub const mair_el3 = mair.el(3);
    pub const midr = systemRegisterPerExceptionLevel(.JustLevelOne, "midr");
    pub const midr_el1 = midr.el(1);
    pub const mpidr = systemRegisterPerExceptionLevel(.JustLevelOne, "mpidr");
    pub const mpidr_el1 = mair.el(1);
    pub const sctlr = systemRegisterPerExceptionLevel(.LevelsOneThroughThree, "sctlr");
    pub const sctlr_el1 = sctlr.el(1);
    pub const sctlr_el2 = sctlr.el(2);
    pub const sctlr_el3 = sctlr.el(3);
    pub const sp = cpuRegister("sp");
    pub const spsr = systemRegisterPerExceptionLevel(.LevelsOneThroughThree, "spsr");
    pub const spsr_el1 = spsr.el(1);
    pub const spsr_el2 = spsr.el(2);
    pub const spsr_el3 = spsr.el(3);
    pub const tcr = systemRegisterPerExceptionLevel(.LevelsOneThroughThree, "tcr");
    pub const tcr_el1 = tcr.el(1);
    pub const tcr_el2 = tcr.el(2);
    pub const tcr_el3 = tcr.el(3);
    pub const ttbr0 = systemRegisterPerExceptionLevel(.LevelsOneThroughThree, "ttbr0");
    pub const ttbr0_el1 = ttbr0.el(1);
    pub const ttbr0_el2 = ttbr0.el(2);
    pub const ttbr0_el3 = ttbr0.el(3);
    pub const vbar = systemRegisterPerExceptionLevel(.LevelsOneThroughThree, "vbar");
    pub const vbar_el1 = vbar.el(1);
    pub const vbar_el2 = vbar.el(2);
    pub const vbar_el3 = vbar.el(3);

    /// Available levels for a system register
    const AvailableLevels = enum {
        /// Available only at level 0
        JustLevelZero,
        /// Available only at level 1
        JustLevelOne,
        /// Available only at levels 1 through 3
        LevelsOneThroughThree,
    };

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
    fn systemRegisterPerExceptionLevel(comptime available_levels: AvailableLevels, comptime register_name: []const u8) type {
        return struct {
            pub inline fn el(exception_level: u2) type {
                const level_string = switch (exception_level) {
                    0 => string: {
                        assert(available_levels == .JustLevelZero);
                        break :string "0";
                    },
                    1 => string: {
                        assert(available_levels == .JustLevelOne or available_levels == .LevelsOneThroughThree);
                        break :string "1";
                    },
                    2 => string: {
                        assert(available_levels == .LevelsOneThroughThree);
                        break :string "2";
                    },
                    3 => string: {
                        assert(available_levels == .LevelsOneThroughThree);
                        break :string "3";
                    },
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
            pub inline fn readSetWrite(bits: usize) void {
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

    pub fn isQemu() bool {
        return cntfrq.el(0).read() != 0;
    }

    pub inline fn wfe() void {
        asm volatile (
            \\ wfe
        );
    }
};

/// Virtual addresses are 30 bits (1GB)
const VirtualAddress = u30;
/// Physical addresses are 30 bits (1GB)
const PhysicalAddress = u30;
/// There are two level 2 entries (512MB each)
const level_2_page_table_len = 2;
/// There are two level 3 tables of 8K entries
const level_3_page_table_len = 2 * 8 * 1024;
/// Page tables must be aligned to 64KB
const table_alignment = 64 * 1024;
/// The entire set of page table entries
var translation_table: [level_3_page_table_len + level_2_page_table_len]usize align(table_alignment) = undefined;
///
/// map 1GB to ram except last 16MB to mmio
pub fn enableFlatMmu() void {
    const page_size = 64 * 1024;
    const start_of_mmio = level_3_page_table_len - (16 * 1024 * 1024 / page_size);
    var table_index: usize = 0;
    while (table_index < start_of_mmio) : (table_index += 1) {
        translation_table[table_index] = table_index * page_size + 0x0703; // normal pte=3 attr index=0 inner shareable=3 af=1
    }
    while (table_index < level_3_page_table_len) : (table_index += 1) {
        translation_table[table_index] = table_index * page_size + 0x0607; // device pte=3 attr index=1 outer shareable=2 af=1
    }
    var x: usize = @ptrToInt(&translation_table);
    while (table_index < translation_table.len) : (table_index += 1) {
        translation_table[table_index] = x | 0x3;
        x += table_alignment;
    }
    Cpu.mair.el(3).write(0x04ff);
    const t0sz = @bitSizeOf(usize) - @bitSizeOf(VirtualAddress);
    Cpu.tcr.el(3).readSetWrite(0x80804000 | t0sz);
    Cpu.ttbr0.el(3).write(@ptrToInt(&translation_table[level_3_page_table_len]));
    Cpu.isb();
    Cpu.sctlr.el(3).readSetWrite(0x1);
    Cpu.isb();
}
