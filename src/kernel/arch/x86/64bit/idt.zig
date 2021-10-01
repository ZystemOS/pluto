const std = @import("std");
const expectEqual = std.testing.expectEqual;

const common_idt = @import("../common/idt.zig");

/// The structure that contains all the information that each IDT entry needs.
pub const IdtEntry = packed struct {
    /// The lower 16 bits of the base address of the interrupt handler offset.
    base_low: u16,

    /// The code segment in the GDT which the handlers will be held.
    selector: u16,

    /// Must be zero, unused.
    zero0: u8 = 0,

    /// The IDT gate type.
    gate_type: u4,

    /// Must be 0 for interrupt and trap gates.
    storage_segment: u1,

    /// The minimum ring level that the calling code must have to run the handler. So user code may
    /// not be able to run some interrupts.
    privilege: u2,

    /// Whether the IDT entry is present.
    present: u1,

    /// The middle 16 bits of the base address of the interrupt handler offset.
    base_middle: u16,

    /// The upper 32 bits of the base address of the interrupt handler offset.
    base_high: u32,

    /// Must be zero, unused.
    zero1: u32 = 0,

    ///
    /// Check whether a IDT gate is open.
    ///
    /// Arguments:
    ///     IN self: IdtEntry - The IDT entry to check.
    ///
    /// Return: bool
    ///     Whether the provided IDT entry is open or not.
    ///
    pub fn isIdtOpen(self: IdtEntry) bool {
        return self.present == 1;
    }

    ///
    /// Initialise a new IDT entry.
    ///
    /// Arguments:
    ///     IN base: u64     - The pointer to the interrupt handler.
    ///     IN selector: u16 - The descriptor segment the interrupt is in. This will usually be the
    ///                        kernels code segment.
    ///     IN gate_type: u4 - The type of interrupt. This will usually be the INTERRUPT_GATE.
    ///     IN privilege: u2 - What privilege to call the interrupt in. This will usually be
    ///                        the kernel ring level 0.
    ///
    /// Return: IdtEntry
    ///     A new IDT entry.
    ///
    pub fn init(base: u64, selector: u16, gate_type: u4, privilege: u2) IdtEntry {
        return .{
            .base_low = @truncate(u16, base),
            .selector = selector,
            .gate_type = gate_type,
            .storage_segment = 0,
            .privilege = privilege,
            .present = 1,
            .base_middle = @truncate(u16, base >> 16),
            .base_high = @truncate(u32, base >> 32),
        };
    }
};

// Check the sizes of the packet struct.
comptime {
    std.debug.assert(@sizeOf(IdtEntry) == 16);
    std.debug.assert(@sizeOf(common_idt.IDT(IdtEntry).IdtPtr) == 10);
}

/// The IDT table.
pub var table: common_idt.IDT(IdtEntry) = common_idt.IDT(IdtEntry){};

fn testHandler() callconv(.Naked) void {}

test "IdtEntry.init alternating bit pattern" {
    const actual = IdtEntry.init(0b0101010101010101010101010101010101010101010101010101010101010101, 0b0101010101010101, 0b0101, 0b01);

    const expected: u128 = 0b010101010101010101010101010101010101010101010101101001010000000001010101010101010101010101010101;

    expectEqual(expected, @bitCast(u128, actual));
}

test "IdtEntry.isIdtOpen" {
    const not_open = IdtEntry{
        .base_low = 0,
        .selector = 0,
        .gate_type = 0,
        .storage_segment = 0,
        .privilege = 0,
        .present = 0,
        .base_middle = 0,
        .base_high = 0,
    };

    const open = IdtEntry{
        .base_low = 0,
        .selector = 0,
        .gate_type = 0,
        .storage_segment = 0,
        .privilege = 0,
        .present = 1,
        .base_middle = 0,
        .base_high = 0,
    };

    // Values don't matter
    const create_open = IdtEntry.init(@ptrToInt(testHandler), 0xFFAA, 0, 3);

    expectEqual(false, not_open.isIdtOpen());
    expectEqual(true, open.isIdtOpen());
    expectEqual(true, create_open.isIdtOpen());
}
