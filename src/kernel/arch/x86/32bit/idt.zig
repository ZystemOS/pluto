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
    zero: u8,

    /// The IDT gate type.
    gate_type: u4,

    /// Must be 0 for interrupt and trap gates.
    storage_segment: u1,

    /// The minimum ring level that the calling code must have to run the handler. So user code may not be able to run some interrupts.
    privilege: u2,

    /// Whether the IDT entry is present.
    present: u1,

    /// The upper 16 bits of the base address of the interrupt handler offset.
    base_high: u16,

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
    ///     IN base: u32     - The pointer to the interrupt handler.
    ///     IN selector: u16 - The descriptor segment the interrupt is in. This will usually be the
    ///                        kernels code segment.
    ///     IN gate_type: u4 - The type of interrupt. This will usually be the INTERRUPT_GATE.
    ///     IN privilege: u2 - What privilege to call the interrupt in. This will usually be
    ///                        the kernel ring level 0.
    ///
    /// Return: IdtEntry
    ///     A new IDT entry.
    ///
    pub fn init(base: u32, selector: u16, gate_type: u4, privilege: u2) IdtEntry {
        return IdtEntry{
            .base_low = @truncate(u16, base),
            .selector = selector,
            .zero = 0,
            .gate_type = gate_type,
            .storage_segment = 0,
            .privilege = privilege,
            .present = 1,
            .base_high = @truncate(u16, base >> 16),
        };
    }
};

// Check the sizes of the packet structs.
comptime {
    std.debug.assert(@sizeOf(IdtEntry) == 8);
    std.debug.assert(@sizeOf(common_idt.IDT(IdtEntry).IdtPtr) == 6);
}

/// The IDT table.
pub var table: common_idt.IDT(IdtEntry) = common_idt.IDT(IdtEntry){};

fn testHandler() callconv(.Naked) void {}

test "IdtEntry.init alternating bit pattern" {
    const actual = IdtEntry.init(0b01010101010101010101010101010101, 0b0101010101010101, 0b0101, 0b01);

    const expected: u64 = 0b0101010101010101101001010000000001010101010101010101010101010101;

    expectEqual(expected, @bitCast(u64, actual));
}

test "IdtEntry.isIdtOpen" {
    const not_open = IdtEntry{
        .base_low = 0,
        .selector = 0,
        .zero = 0,
        .gate_type = 0,
        .storage_segment = 0,
        .privilege = 0,
        .present = 0,
        .base_high = 0,
    };

    const open = IdtEntry{
        .base_low = 0,
        .selector = 0,
        .zero = 0,
        .gate_type = 0,
        .storage_segment = 0,
        .privilege = 0,
        .present = 1,
        .base_high = 0,
    };

    // Values don't matter
    const create_open = IdtEntry.init(@ptrToInt(testHandler), 0xFFAA, 0, 3);

    expectEqual(false, not_open.isIdtOpen());
    expectEqual(true, open.isIdtOpen());
    expectEqual(true, create_open.isIdtOpen());
}
