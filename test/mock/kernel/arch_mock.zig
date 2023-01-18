const std = @import("std");
const builtin = @import("builtin");
const pluto = @import("pluto");
const arch = @import("arch");
const pci = @import("pci_mock.zig");
const gdt = @import("gdt_mock.zig");
const idt = @import("idt_mock.zig");
const paging = @import("paging_mock.zig");
pub const cmos_mock = @import("cmos_mock.zig");
pub const vga_mock = @import("vga_mock.zig");
pub const pic_mock = @import("pic_mock.zig");
pub const idt_mock = @import("idt_mock.zig");
pub const pci_mock = @import("pci_mock.zig");
const x86_paging = arch.paging;
const vmm = pluto.vmm;
const mem = pluto.mem;
const Serial = pluto.serial.Serial;
const TTY = pluto.tty.TTY;
const Keyboard = pluto.keyboard.Keyboard;
const task = pluto.task;
const Allocator = std.mem.Allocator;
const MemProfile = mem.MemProfile;

pub const Device = pci.PciDeviceInfo;
pub const DateTime = struct {
    second: u32,
    minute: u32,
    hour: u32,
    day: u32,
    month: u32,
    year: u32,
    century: u32,
    day_of_week: u32,
};

const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

pub const CpuState = struct {
    ss: u32,
    gs: u32,
    fs: u32,
    es: u32,
    ds: u32,
    edi: u32,
    esi: u32,
    ebp: u32,
    esp: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    int_num: u32,
    error_code: u32,
    eip: u32,
    cs: u32,
    eflags: u32,
    user_esp: u32,
    user_ss: u32,

    pub fn empty() CpuState {
        return .{
            .ss = undefined,
            .gs = undefined,
            .fs = undefined,
            .es = undefined,
            .ds = undefined,
            .edi = undefined,
            .esi = undefined,
            .ebp = undefined,
            .esp = undefined,
            .ebx = undefined,
            .edx = undefined,
            .ecx = undefined,
            .eax = undefined,
            .int_num = undefined,
            .error_code = undefined,
            .eip = undefined,
            .cs = undefined,
            .eflags = undefined,
            .user_esp = undefined,
            .user_ss = undefined,
        };
    }
};

pub const VmmPayload = switch (builtin.cpu.arch) {
    .i386 => *x86_paging.Directory,
    else => unreachable,
};

pub const KERNEL_VMM_PAYLOAD: VmmPayload = switch (builtin.cpu.arch) {
    .i386 => &x86_paging.kernel_directory,
    else => unreachable,
};
pub const MEMORY_BLOCK_SIZE: u32 = paging.PAGE_SIZE_4KB;
pub const STACK_SIZE: u32 = MEMORY_BLOCK_SIZE / @sizeOf(u32);
pub const VMM_MAPPER: vmm.Mapper(VmmPayload) = .{ .mapFn = map, .unmapFn = unmap };
pub const BootPayload = u8;
pub const Task = task.Task;

// The virtual/physical start/end of the kernel code
var KERNEL_PHYSADDR_START: u32 = 0x00100000;
var KERNEL_PHYSADDR_END: u32 = 0x01000000;
var KERNEL_VADDR_START: u32 = 0xC0100000;
var KERNEL_VADDR_END: u32 = 0xC1100000;
var KERNEL_ADDR_OFFSET: u32 = 0xC0000000;

pub fn map(start: usize, end: usize, p_start: usize, p_end: usize, attrs: vmm.Attributes, allocator: Allocator, payload: VmmPayload) !void {
    _ = start;
    _ = end;
    _ = p_start;
    _ = p_end;
    _ = attrs;
    _ = allocator;
    _ = payload;
}
pub fn unmap(start: usize, end: usize, allocator: Allocator, payload: VmmPayload) !void {
    _ = start;
    _ = end;
    _ = allocator;
    _ = payload;
}

pub fn out(port: u16, data: anytype) void {
    return mock_framework.performAction("out", void, .{ port, data });
}

pub fn in(comptime Type: type, port: u16) Type {
    return mock_framework.performAction("in", Type, .{port});
}

pub fn ioWait() void {
    return mock_framework.performAction("ioWait", void, .{});
}

pub fn lgdt(gdt_ptr: *const gdt.GdtPtr) void {
    return mock_framework.performAction("lgdt", void, .{gdt_ptr});
}

pub fn sgdt() gdt.GdtPtr {
    return mock_framework.performAction("sgdt", gdt.GdtPtr, .{});
}

pub fn ltr(offset: u16) void {
    return mock_framework.performAction("ltr", void, .{offset});
}

pub fn lidt(idt_ptr: *const idt.IdtPtr) void {
    return mock_framework.performAction("lidt", void, .{idt_ptr});
}

pub fn sidt() idt.IdtPtr {
    return mock_framework.performAction("sidt", idt.IdtPtr, .{});
}

pub fn enableInterrupts() void {
    return mock_framework.performAction("enableInterrupts", void, .{});
}

pub fn disableInterrupts() void {
    return mock_framework.performAction("disableInterrupts", void, .{});
}

pub fn halt() void {
    return mock_framework.performAction("halt", void, .{});
}

pub fn spinWait() noreturn {
    while (true) {}
}

pub fn haltNoInterrupts() noreturn {
    while (true) {}
}

pub fn initSerial(boot_payload: BootPayload) Serial {
    // Suppress unused variable warnings
    _ = boot_payload;
    return .{ .write = undefined };
}

pub fn initTTY(boot_payload: BootPayload) TTY {
    // Suppress unused variable warnings
    _ = boot_payload;
    return .{
        .print = undefined,
        .setCursor = undefined,
        .cols = undefined,
        .rows = undefined,
        .clear = null,
    };
}

pub fn initMem(payload: BootPayload) Allocator.Error!mem.MemProfile {
    // Suppress unused variable warnings
    _ = payload;
    return MemProfile{
        .vaddr_end = @ptrCast([*]u8, &KERNEL_VADDR_END),
        .vaddr_start = @ptrCast([*]u8, &KERNEL_VADDR_START),
        .physaddr_end = @ptrCast([*]u8, &KERNEL_PHYSADDR_END),
        .physaddr_start = @ptrCast([*]u8, &KERNEL_PHYSADDR_START),
        // Total memory available including the initial 1MiB that grub doesn't include
        .mem_kb = 0,
        .fixed_allocator = undefined,
        .virtual_reserved = undefined,
        .physical_reserved = undefined,
        .modules = undefined,
    };
}

pub fn initTask(t: *Task, entry_point: usize, allocator: Allocator, set_up_stack: bool) Allocator.Error!void {
    // Suppress unused variable warnings
    _ = t;
    _ = entry_point;
    _ = allocator;
    _ = set_up_stack;
}

pub fn initKeyboard(allocator: Allocator) Allocator.Error!?*Keyboard {
    // Suppress unused variable warnings
    _ = allocator;
    return null;
}

pub fn getDevices(allocator: Allocator) Allocator.Error![]Device {
    // Suppress unused variable warnings
    _ = allocator;
    return &[_]Device{};
}

pub fn getDateTime() DateTime {
    // TODO: Use the std lib std.time.timestamp() and convert
    // Hard code 12:12:13 12/12/12 for testing
    return .{
        .second = 13,
        .minute = 12,
        .hour = 12,
        .day = 12,
        .month = 12,
        .year = 2012,
        .century = 2000,
        .day_of_week = 4,
    };
}

pub fn init(mem_profile: *const MemProfile) void {
    // Suppress unused variable warnings
    _ = mem_profile;
    // I'll get back to this as this doesn't effect the current testing.
    // When I come on to the mem.zig testing, I'll fix :)
    //return mock_framework.performAction("init", void, mem_profile);
}

// User defined mocked functions

pub fn mock_disableInterrupts() void {}

pub fn mock_enableInterrupts() void {}

pub fn mock_ioWait() void {}
