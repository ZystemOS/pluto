const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = @import("mem_mock.zig");
const MemProfile = mem.MemProfile;
const gdt = @import("gdt_mock.zig");
const idt = @import("idt_mock.zig");
const multiboot = @import("../../../src/kernel/multiboot.zig");

const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

pub const InterruptContext = struct {
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
    ss: u32,
};

pub fn outb(port: u16, data: u8) void {
    return mock_framework.performAction("outb", void, port, data);
}

pub fn inb(port: u16) u8 {
    return mock_framework.performAction("inb", u8, port);
}

pub fn ioWait() void {
    return mock_framework.performAction("ioWait", void);
}

pub fn lgdt(gdt_ptr: *const gdt.GdtPtr) void {
    return mock_framework.performAction("lgdt", void, gdt_ptr);
}

pub fn sgdt() gdt.GdtPtr {
    return mock_framework.performAction("sgdt", gdt.GdtPtr);
}

pub fn ltr(offset: u16) void {
    return mock_framework.performAction("ltr", void, offset);
}

pub fn lidt(idt_ptr: *const idt.IdtPtr) void {
    return mock_framework.performAction("lidt", void, idt_ptr);
}

pub fn sidt() idt.IdtPtr {
    return mock_framework.performAction("sidt", idt.IdtPtr);
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

pub fn init(mb_info: *multiboot.multiboot_info_t, mem_profile: *const MemProfile, allocator: *Allocator) void {
    // I'll get back to this as this doesn't effect the GDT testing.
    // When I come on to the mem.zig testing, I'll fix :)
    //return mock_framework.performAction("init", void, mem_profile, allocator);
}

// User defined mocked functions

pub fn mock_disableInterrupts() void {}

pub fn mock_enableInterrupts() void {}
