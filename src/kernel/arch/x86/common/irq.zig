const std = @import("std");
const builtin = std.builtin;
const is_test = builtin.is_test;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const log = std.log.scoped(.irq);
const build_options = @import("build_options");
const panic = @import("../../../panic.zig").panic;
const mock_path = build_options.arch_mock_path;
const arch = @import("arch.zig");
const idt = @import("idt.zig");
const pic = if (is_test) @import(mock_path ++ "pic_mock.zig") else @import("pic.zig");
const interrupts = @import("interrupts.zig");

/// The error set for the IRQ. This will be from installing a IRQ handler.
const IrqError = error{
    /// The IRQ index is invalid.
    InvalidIrq,

    /// A IRQ handler already exists.
    IrqExists,
};

/// The total number of IRQ.
const NUMBER_OF_ENTRIES: u16 = 16;

// The offset from the interrupt number where the IRQs are.
pub const IRQ_OFFSET: u16 = 32;

/// The list of IRQ handlers initialised to unhandled.
var irq_handlers: [NUMBER_OF_ENTRIES]?interrupts.InterruptHandler = [_]?interrupts.InterruptHandler{null} ** NUMBER_OF_ENTRIES;

///
/// Open an IDT entry with index and handler. This will also handle the errors.
///
/// Arguments:
///     IN comptime IdtEntry: type       - The type of the IDT entry.
///     IN table: *idt.IDT(IdtEntry)     - The IDT to open the interrupt in.
///     IN index: u8                     - The IDT interrupt number to open.
///     IN handler: idt.InterruptHandler - The IDT handler to register for the interrupt number.
///
fn openIrq(comptime IdtEntry: type, table: *idt.IDT(IdtEntry), index: u8, handler: idt.InterruptHandler) void {
    table.openInterruptGate(index, handler) catch |err| switch (err) {
        error.IdtEntryExists => {
            panic(@errorReturnTrace(), "Error opening IRQ number: {} exists", .{index});
        },
    };
}

///
/// The IRQ handler that each of the IRQs will call when a interrupt happens. If the handler
/// performs a context switch, then will return the new stack pointer of the the new task or return
/// the same stack pointer of the original task.
///
/// Arguments:
///     IN ctx: *arch.CpuState - Pointer to the interrupt context containing the contents
///                              of the register at the time of the interrupt.
///
/// Return: usize
///     The stack pointer of the stack to switch to (if switching).
///
pub fn irqHandler(ctx: *arch.CpuState) usize {
    // Get the IRQ index, by getting the interrupt number and subtracting the offset.
    if (ctx.int_num < IRQ_OFFSET) {
        panic(@errorReturnTrace(), "Not an IRQ number: {}\n", .{ctx.int_num});
    }

    var ret_esp = @ptrToInt(ctx);

    const irq_offset = ctx.int_num - IRQ_OFFSET;
    if (isValidIrq(irq_offset)) {
        // IRQ index is valid so can truncate
        const irq_num = @truncate(u8, irq_offset);
        if (irq_handlers[irq_num]) |handler| {
            // Make sure it isn't a spurious irq
            if (!pic.spuriousIrq(irq_num)) {
                ret_esp = handler(ctx);
                // Send the end of interrupt command
                pic.sendEndOfInterrupt(irq_num);
            }
        } else {
            panic(@errorReturnTrace(), "IRQ not registered: {}", .{irq_num});
        }
    } else {
        panic(@errorReturnTrace(), "Invalid IRQ index: {}", .{irq_offset});
    }
    return ret_esp;
}

///
/// Check whether the IRQ index is valid. This will have to be less than NUMBER_OF_ENTRIES.
///
/// Arguments:
///     IN irq_num: usize - The IRQ index to test.
///
/// Return: bool
///     Whether the IRQ index is valid.
///
pub fn isValidIrq(irq_num: usize) bool {
    return irq_num < NUMBER_OF_ENTRIES;
}

///
/// Register a IRQ by setting its interrupt handler to the given function. This will also clear the
/// mask bit in the PIC so interrupts can happen for this IRQ.
///
/// Arguments:
///     IN irq_num: u8                          - The IRQ number to register.
///     IN handler: interrupts.InterruptHandler - The IRQ handler to register. This is what will be
///                                               called when this interrupt happens.
///
/// Errors: IrqError
///     IrqError.InvalidIrq - If the IRQ index is invalid (see isValidIrq).
///     IrqError.IrqExists  - If the IRQ handler has already been registered.
///
pub fn registerIrq(irq_num: u8, handler: interrupts.InterruptHandler) IrqError!void {
    // Check whether the IRQ index is valid.
    if (isValidIrq(irq_num)) {
        // Check if a handler has already been registered.
        if (irq_handlers[irq_num]) |_| {
            return IrqError.IrqExists;
        } else {
            // Register the handler and clear the PIC mask so interrupts can happen.
            irq_handlers[irq_num] = handler;
            pic.clearMask(irq_num);
        }
    } else {
        return IrqError.InvalidIrq;
    }
}

///
/// Initialise the IRQ interrupts by first remapping the port addresses and then opening up all
/// the IDT interrupt gates for each IRQ.
///
/// Arguments:
///     IN comptime IdtEntry: type   - The type for the IDT.
///     IN table: *idt.IDT(IdtEntry) - The IDT.
///
pub fn init(comptime IdtEntry: type, table: *idt.IDT(IdtEntry)) void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    comptime var i = IRQ_OFFSET;
    inline while (i < IRQ_OFFSET + 16) : (i += 1) {
        openIrq(IdtEntry, table, i, interrupts.getInterruptStub(i));
    }

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(IdtEntry),
        else => {},
    }
}

/// A test IDT entry. This will just take the init parameters and save them.
const TestIdtEntry = struct {
    base: usize,
    selector: u16,
    gate_type: u4,
    privilege: u2,

    pub fn isIdtOpen(self: TestIdtEntry) bool {
        return false;
    }

    pub fn init(base: usize, selector: u16, gate_type: u4, privilege: u2) TestIdtEntry {
        return .{
            .base = base,
            .selector = selector,
            .gate_type = gate_type,
            .privilege = privilege,
        };
    }
};

fn testFunction0() callconv(.Naked) void {}

fn testFunction1(ctx: *arch.CpuState) u32 {
    return 0;
}

fn testFunction2(ctx: *arch.CpuState) u32 {
    return 0;
}

test "isValidIrq" {
    comptime var i = 0;
    inline while (i < NUMBER_OF_ENTRIES) : (i += 1) {
        expect(isValidIrq(i));
    }

    expect(!isValidIrq(200));
}

test "openIrq" {
    var table = idt.IDT(TestIdtEntry){};
    openIrq(TestIdtEntry, &table, index, handler);
}

test "registerIrq re-register irq handler" {
    pic.initTest();
    defer pic.freeTest();

    pic.addTestParams("clearMask", .{@as(u16, 0)});

    // Check all handlers are null
    for (irq_handlers) |handler| {
        expect(null == handler);
    }

    try registerIrq(0, testFunction1);
    expectError(IrqError.IrqExists, registerIrq(0, testFunction2));

    for (irq_handlers) |handler, i| {
        if (i != 0) {
            expect(null == handler);
        } else {
            expectEqual(testFunction1, handler.?);
        }
    }

    irq_handlers[0] = null;
}

test "registerIrq register irq handler" {
    pic.initTest();
    defer pic.freeTest();

    pic.addTestParams("clearMask", .{@as(u16, 0)});

    // Check all handlers are null
    for (irq_handlers) |handler| {
        expect(null == handler);
    }

    try registerIrq(0, testFunction1);

    for (irq_handlers) |handler, i| {
        if (i != 0) {
            expect(null == handler);
        } else {
            expectEqual(testFunction1, handler.?);
        }
    }

    irq_handlers[0] = null;
}

test "registerIrq invalid irq index" {
    expectError(IrqError.InvalidIrq, registerIrq(200, testFunction1));
}

///
/// Test that all handlers are null at initialisation.
///
fn rt_unregisteredHandlers() void {
    // Ensure all ISR are not registered yet
    for (irq_handlers) |handler, i| {
        if (handler) |_| {
            panic(@errorReturnTrace(), "FAILURE: Handler found for IRQ: {}-{}\n", .{ i, handler });
        }
    }

    log.info("Tested registered handlers\n", .{});
}

///
/// Test that all IDT entries for the IRQs are open.
///
/// Arguments:
///     IN comptime IdtEntry: type - The type of the IDT entry.
///
fn rt_openedIdtEntries(comptime IdtEntry: type) void {
    const loaded_idt = arch.sidt(IdtEntry);
    const idt_entries = @intToPtr([*]IdtEntry, @ptrToInt(loaded_idt.base))[0..idt.NUMBER_OF_ENTRIES];

    for (idt_entries) |entry, i| {
        if (i >= IRQ_OFFSET and isValidIrq(i - IRQ_OFFSET)) {
            if (!entry.isIdtOpen()) {
                panic(@errorReturnTrace(), "FAILURE: IDT entry for {} is not open\n", .{i});
            }
        }
    }

    log.info("Tested opened IDT entries\n", .{});
}

///
/// Run all the runtime tests.
///
/// Arguments:
///     IN comptime IdtEntry: type - The type of the IDT entry.
///
pub fn runtimeTests(comptime IdtEntry: type) void {
    rt_unregisteredHandlers();
    rt_openedIdtEntries(IdtEntry);
}
