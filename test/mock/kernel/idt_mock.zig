const builtin = @import("builtin");
const src_idt = switch (builtin.arch) {
    .i386 => @import("../../../src/kernel/arch/x86/idt.zig"),
    .x86_64 => @import("../../../src/kernel/arch/x86_64/idt.zig"),
    else => unreachable,
};
const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

pub const IdtEntry = packed struct {
    base_low: u16,
    selector: u16,
    zero: u8,
    gate_type: u4,
    storage_segment: u1,
    privilege: u2,
    present: u1,
    base_high: u16,
};

// Need to use the type from the source file so that types match
pub const IdtPtr = src_idt.IdtPtr;

pub const InterruptHandler = src_idt.InterruptHandler;

pub const IdtError = src_idt.IdtError;

const TASK_GATE: u4 = 0x5;
const INTERRUPT_GATE: u4 = 0xE;
const TRAP_GATE: u4 = 0xF;

const PRIVILEGE_RING_0: u2 = 0x0;
const PRIVILEGE_RING_1: u2 = 0x1;
const PRIVILEGE_RING_2: u2 = 0x2;
const PRIVILEGE_RING_3: u2 = 0x3;

pub const NUMBER_OF_ENTRIES: u16 = 256;

const TABLE_SIZE: u16 = @sizeOf(IdtEntry) * NUMBER_OF_ENTRIES - 1;

pub fn isIdtOpen(entry: IdtEntry) bool {
    return mock_framework.performAction("isIdtOpen", bool, .{entry});
}

pub fn openInterruptGate(index: u8, handler: InterruptHandler) IdtError!void {
    return mock_framework.performAction("openInterruptGate", IdtError!void, .{ index, handler });
}

pub fn init() void {
    return mock_framework.performAction("init", void);
}
