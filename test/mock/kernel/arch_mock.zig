const std = @import("std");
const MemProfile = @import("mem_mock.zig").MemProfile;
const expect = std.testing.expect;
const warn = std.debug.warn;

const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

pub const InterruptContext = struct {
    // Extra segments
    gs: u32,
    fs: u32,
    es: u32,
    ds: u32,

    // Destination, source, base pointer
    edi: u32,
    esi: u32,
    ebp: u32,
    esp: u32,

    // General registers
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,

    // Interrupt number and error code
    int_num: u32,
    error_code: u32,

    // Instruction pointer, code segment and flags
    eip: u32,
    cs: u32,
    eflags: u32,
    user_esp: u32,
    ss: u32,
};

pub fn init(mem_profile: *const MemProfile, allocator: *std.mem.Allocator, comptime options: type) void {
    //return mock_framework.performAction("init", void, mem_profile, allocator);
}

pub fn outb(port: u16, data: u8) void {
    return mock_framework.performAction("outb", void, port, data);
}

pub fn inb(port: u16) u8 {
    return mock_framework.performAction("inb", u8, port);
}

pub fn ioWait() void {
    return mock_framework.performAction("ioWait", void);
}

pub fn registerInterruptHandler(int: u16, ctx: fn (ctx: *InterruptContext) void) void {
    return mock_framework.performAction("registerInterruptHandler", void, int, ctx);
}

pub fn lgdt(gdt_ptr: *const gdt.GdtPtr) void {
    return mock_framework.performAction("lgdt", void, gdt_ptr.*);
}

pub fn ltr() void {
    return mock_framework.performAction("ltr", void);
}

pub fn lidt(idt_ptr: *const idt.IdtPtr) void {
    return mock_framework.performAction("lidt", void, idt_ptr.*);
}

pub fn enableInterrupts() void {
    return mock_framework.performAction("enableInterrupts", void);
}

pub fn disableInterrupts() void {
    return mock_framework.performAction("disableInterrupts", void);
}

pub fn halt() void {
    return mock_framework.performAction("halt", void);
}

pub fn spinWait() noreturn {
    while (true) {}
}

pub fn haltNoInterrupts() noreturn {
    while (true) {}
}
