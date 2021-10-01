const std = @import("std");
const log = std.log.scoped(.idt);
const builtin = std.builtin;
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");
const gdt = @import("gdt.zig");
const panic = @import("../../../panic.zig").panic;

/// The function type for the interrupt handler
pub const InterruptHandler = fn () callconv(.Naked) void;

/// The total number of entries the IDT can have (2^8).
pub const NUMBER_OF_ENTRIES: u16 = 256;

///
/// The interrupt descriptor table structure for handling IDT operations. This allows common use
/// across 32 and 64 bit versions of the X86 IDT as the IDT entry is the only main difference.
///
/// Arguments:
///     IN comptime IdtEntry: type - The type of the IDT entry structure.
///
/// Return: type
///     The IDT structure.
///
pub fn IDT(comptime IdtEntry: type) type {
    return struct {
        /// The IDT entry table of NUMBER_OF_ENTRIES entries. Initially all zeroed.
        idt_entries: [NUMBER_OF_ENTRIES]IdtEntry = [_]IdtEntry{undefined} ** NUMBER_OF_ENTRIES,

        /// The IDT pointer that the CPU is loaded with that contains the base address of the IDT
        /// and the size. The total size of all the IDT entries (minus 1). The base address will
        /// need to be set on init().
        idt_ptr: IdtPtr = IdtPtr{
            .limit = @sizeOf(IdtEntry) * NUMBER_OF_ENTRIES - 1,
            .base = undefined,
        },

        const Self = @This();

        /// The error set for the IDT
        const IdtError = error{
            /// A IDT entry already exists for the provided index.
            IdtEntryExists,
        };

        /// The IDT pointer structure that contains the pointer to the beginning of the IDT and the number
        /// of the table (minus 1). Used to load the IST with LIDT instruction.
        pub const IdtPtr = packed struct {
            /// The total size of the IDT (minus 1) in bytes.
            limit: u16,

            /// The base address where the IDT is located.
            base: *const IdtEntry,
        };

        /// The base addresses aren't used, so set these to 0. When a interrupt happens, interrupts are not
        /// automatically disabled. This is used for referencing the TSS descriptor in the GDT.
        const TASK_GATE: u4 = 0x5;

        /// Used to specify a interrupt service routine (ISR). When a interrupt happens, interrupts are
        /// automatically disabled then enabled upon the IRET instruction which restores the saved EFLAGS.
        const INTERRUPT_GATE: u4 = 0xE;

        /// Used to specify a interrupt service routine (ISR). When a interrupt happens, interrupts are not
        /// automatically disabled and doesn't restores the saved EFLAGS upon the IRET instruction.
        const TRAP_GATE: u4 = 0xF;

        /// Privilege level 0. Kernel land. The privilege level the calling descriptor minimum will have.
        const PRIVILEGE_RING_0: u2 = 0x0;

        /// Privilege level 1. The privilege level the calling descriptor minimum will have.
        const PRIVILEGE_RING_1: u2 = 0x1;

        /// Privilege level 2. The privilege level the calling descriptor minimum will have.
        const PRIVILEGE_RING_2: u2 = 0x2;

        /// Privilege level 3. User land. The privilege level the calling descriptor minimum will have.
        const PRIVILEGE_RING_3: u2 = 0x3;

        ///
        /// Open a interrupt gate with a given index and a handler to call.
        ///
        /// Arguments:
        ///     IN index: u8                 - The interrupt number to open.
        ///     IN handler: InterruptHandler - The interrupt handler for the interrupt.
        ///
        /// Errors:
        ///     IdtError.InvalidIdtEntry - If the interrupt number is invalid, see isValidInterruptNumber.
        ///     IdtError.IdtEntryExists  - If the interrupt has already been registered.
        ///
        pub fn openInterruptGate(self: *Self, index: u8, handler: InterruptHandler) IdtError!void {
            // As the IDT is a u8, that maximum can only be 255 which is the maximum IDT entries.
            // So there can't be a out of bounds.
            if (self.idt_entries[index].isIdtOpen()) {
                return IdtError.IdtEntryExists;
            }

            self.idt_entries[index] = IdtEntry.init(@ptrToInt(handler), gdt.KERNEL_CODE_OFFSET, INTERRUPT_GATE, PRIVILEGE_RING_0);
        }
    };
}

///
/// Initialise the Interrupt Descriptor Table by updating the base address of the IDT pointer to
/// the address of the IDT table and load the IDT pointer into the IDT register.
///
/// Arguments:
///     IN comptime IdtEntry: type - The type of the IDT entry structure.
///     IN table: *IDT(IdtEntry)   - The pointer to the IDT table.
///
pub fn init(comptime IdtEntry: type, table: *IDT(IdtEntry)) void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    table.idt_ptr.base = &table.idt_entries[0];
    arch.lidt(IdtEntry, &table.idt_ptr);

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(IdtEntry, table),
        else => {},
    }
}

fn testHandler() callconv(.Naked) void {}

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

fn mock_lidt(ptr: *const IdtPtr(IdtEntry)) void {
    expectEqual(ptr.limit, TABLE_SIZE);
    expectEqual(ptr.base, &idt_entries[0]);
}

test "IDT.openInterruptGate" {
    const index: u8 = 100;
    const idt = IDT(TestIdtEntry){};

    try idt.openInterruptGate(index, testHandler);
    expectError(IdtError.IdtEntryExists, idt.openInterruptGate(index, testHandler));

    const test_fn_addr = @ptrToInt(testHandler);

    const expected_entry = TestIdtEntry{
        .base = test_fn_addr,
        .selector = gdt.KERNEL_CODE_OFFSET,
        .gate_type = INTERRUPT_GATE,
        .privilege = PRIVILEGE_RING_0,
    };

    expectEqual(expected_entry, idt.idt_entries[index]);
}

test "init" {
    arch.initTest();
    defer arch.freeTest();

    arch.addConsumeFunction("lidt", mock_lidt);

    var idt = IDT(TestIdtEntry){};
    init(TestIdtEntry, &idt);

    expectEqual(table.idt_ptr.base, &table.idt_entries[0]);
}

///
/// Check that the IDT table was loaded properly by getting the previously loaded table and
/// compare the limit and base address.
///
/// Arguments:
///     IN comptime IdtEntry: type     - The type of the IDT entry.
///     IN table: *const IDT(IdtEntry) - The pointer to the initialised IDT table.
///
fn rt_loadedIDTSuccess(comptime IdtEntry: type, table: *const IDT(IdtEntry)) void {
    const loaded_idt = arch.sidt(IdtEntry);
    if (table.idt_ptr.limit != loaded_idt.limit) {
        panic(@errorReturnTrace(), "FAILURE: IDT not loaded properly: 0x{X} != 0x{X}\n", .{ table.idt_ptr.limit, loaded_idt.limit });
    }
    if (table.idt_ptr.base != loaded_idt.base) {
        panic(@errorReturnTrace(), "FAILURE: IDT not loaded properly: 0x{X} != {X}\n", .{ table.idt_ptr.base, loaded_idt.base });
    }
    log.info("Tested loading IDT\n", .{});
}

///
/// Run all the runtime tests.
///
/// Arguments:
///     IN comptime IdtEntry: type     - The type of the IDT entry.
///     IN table: *const IDT(IdtEntry) - The pointer to the initialised IDT table.
///
pub fn runtimeTests(comptime IdtEntry: type, table: *const IDT(IdtEntry)) void {
    rt_loadedIDTSuccess(IdtEntry, table);
}
