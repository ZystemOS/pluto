const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = @import("mem_mock.zig");
const MemProfile = mem.MemProfile;
const gdt = @import("gdt_mock.zig");
const idt = @import("idt_mock.zig");
const vmm = @import("vmm_mock.zig");
const paging = @import("paging_mock.zig");
const Serial = @import("../../../src/kernel/serial.zig").Serial;
const TTY = @import("../../../src/kernel/tty.zig").TTY;
const Keyboard = @import("../../../src/kernel/keyboard.zig").Keyboard;

pub const task = @import("task_mock.zig");

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
};

pub const VmmPayload = u8;
pub const KERNEL_VMM_PAYLOAD: usize = 0;
pub const MEMORY_BLOCK_SIZE: u32 = paging.PAGE_SIZE_4KB;
pub const STACK_SIZE: u32 = MEMORY_BLOCK_SIZE / @sizeOf(u32);
pub const VMM_MAPPER: vmm.Mapper(VmmPayload) = undefined;
pub const BootPayload = u8;
pub const Task = task.Task;

// The virtual/physical start/end of the kernel code
var KERNEL_PHYSADDR_START: u32 = 0x00100000;
var KERNEL_PHYSADDR_END: u32 = 0x01000000;
var KERNEL_VADDR_START: u32 = 0xC0100000;
var KERNEL_VADDR_END: u32 = 0xC1100000;
var KERNEL_ADDR_OFFSET: u32 = 0xC0000000;

pub fn outb(port: u16, data: u8) void {
    return mock_framework.performAction("outb", void, .{ port, data });
}

pub fn inb(port: u16) u8 {
    return mock_framework.performAction("inb", u8, .{port});
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
    return .{ .write = undefined };
}

pub fn initTTY(boot_payload: BootPayload) TTY {
    return .{
        .print = undefined,
        .setCursor = undefined,
        .cols = undefined,
        .rows = undefined,
        .clear = null,
    };
}

pub fn initMem(payload: BootPayload) Allocator.Error!mem.MemProfile {
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

pub fn initTaskStack(entry_point: usize, allocator: *Allocator) Allocator.Error!struct { stack: []u32, pointer: usize } {
    const ret = .{ .stack = &([_]u32{}), .pointer = 0 };
    return ret;
}

pub fn initKeyboard(allocator: *Allocator) Allocator.Error!?*Keyboard {
    return null;
}

pub fn init(mem_profile: *const MemProfile) void {
    // I'll get back to this as this doesn't effect the current testing.
    // When I come on to the mem.zig testing, I'll fix :)
    //return mock_framework.performAction("init", void, mem_profile, allocator);
}

// User defined mocked functions

pub fn mock_disableInterrupts() void {}

pub fn mock_enableInterrupts() void {}

pub fn mock_ioWait() void {}
