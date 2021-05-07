const std = @import("std");
const expectEqual = std.testing.expectEqual;
const log = std.log.scoped(.x86_64_gdt);
const builtin = @import("builtin");
const is_test = builtin.is_test;
const panic = @import("../../../panic.zig").panic;
const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");

usingnamespace @import("../common/gdt.zig");

/// The TSS entry structure
const Tss = packed struct {
    reserved0: u32 = 0,

    /// Stack pointer for ring 0.
    rsp0: u64 = 0,

    /// Stack pointer for ring 1.
    rsp1: u64 = 0,

    /// Stack pointer for ring 2.
    rsp2: u64 = 0,
    reserved1: u64 = 0,

    /// Interrupt Stack Table. Known good stack pointers for handling interrupts. There are 7 of them.
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u32 = 0,

    /// The 16-bit offset to the I/O permission bit map from the 64-bit TSS base.
    io_permissions_base_offset: u16 = 0,
};

// Check the sizes of the packet structs.
comptime {
    std.debug.assert(@sizeOf(Tss) == 106);
}

/// The total number of entries in the GDT including: null, kernel code, kernel data, user code,
/// user data and the TSS.
const NUMBER_OF_ENTRIES: u16 = 0x07;

/// The size of the GTD in bytes (minus 1).
const TABLE_SIZE: u16 = @sizeOf(GdtEntry) * NUMBER_OF_ENTRIES - 1;

/// The index of the task state segment GDT entry. Lower 32 bit base address.
const TSS_INDEX_LOWER: u16 = 0x05;

/// The index of the task state segment GDT entry. Upper 32 bit base address.
const TSS_INDEX_UPPER: u16 = 0x06;

/// The GDT pointer object used for loading the GDT entries.
const gdt_ptr: GdtPtr = GdtPtr{
    .limit = TABLE_SIZE,
    .base = &gdt_entries[0],
};

/// The 64 bit TSS entry.
const tss_entry: Tss = Tss{};

// ----------
// The offsets into the GDT where each segment resides.
// ----------

/// The offset of the kernel code GDT entry.
pub const KERNEL_CODE_OFFSET: u16 = 0x08;

/// The offset of the kernel data GDT entry.
pub const KERNEL_DATA_OFFSET: u16 = 0x10;

/// The offset of the user code GDT entry.
pub const USER_CODE_OFFSET: u16 = 0x18;

/// The offset of the user data GDT entry.
pub const USER_DATA_OFFSET: u16 = 0x20;

/// The offset of the lower TSS entry.
pub const TSS_LOWER_OFFSET: u16 = 0x28;

/// The offset of the upper TSS entry.
pub const TSS_UPPER_OFFSET: u16 = 0x30;

/// The array of GDT entries
var gdt_entries: [NUMBER_OF_ENTRIES]GdtEntry = [_]GdtEntry{
    // Null descriptor
    makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS),

    // Kernel code descriptor
    makeGdtEntry(0, 0xFFFFF, KERNEL_SEGMENT_CODE, PAGING_64_BIT),

    // Kernel data descriptor
    makeGdtEntry(0, 0xFFFFF, KERNEL_SEGMENT_DATA, PAGING_64_BIT),

    // User code descriptor
    makeGdtEntry(0, 0xFFFFF, USER_SEGMENT_CODE, PAGING_64_BIT),

    // User data descriptor
    makeGdtEntry(0, 0xFFFFF, USER_SEGMENT_DATA, PAGING_64_BIT),

    // Lower TSS. Will be initialised at runtime.
    makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS),

    // Upper TSS. Will be initialised at runtime.
    makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS),
};

///
/// Initialise the Global Descriptor table.
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    // Initialise the TSS
    gdt_entries[TSS_INDEX_LOWER] = makeGdtEntry(@truncate(u32, @ptrToInt(&tss_entry)), @sizeOf(Tss) - 1, TSS_SEGMENT, NULL_FLAGS);
    gdt_entries[TSS_INDEX_UPPER] = makeGdtEntry(@truncate(u16, @ptrToInt(&tss_entry) >> 48), @truncate(u16, @ptrToInt(&tss_entry) >> 32), NULL_SEGMENT, NULL_FLAGS);

    // Load the GDT
    arch.lgdt(&gdt_ptr);

    // Load the TSS
    arch.ltr(TSS_LOWER_OFFSET);

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(),
        else => {},
    }
}

fn mock_lgdt(ptr: *const GdtPtr) void {
    expectEqual(ptr.limit, TABLE_SIZE);
    expectEqual(ptr.base, &gdt_entries[0]);
}

test "gdt_entries expected entries" {
    {
        const expected: u64 = 0;
        expectEqual(expected, @bitCast(u64, gdt_entries[0]));
    }
    {
        const expected: u64 = 0xAF9A000000FFFF;
        expectEqual(expected, @bitCast(u64, gdt_entries[1]));
    }
    {
        const expected: u64 = 0xAF92000000FFFF;
        expectEqual(expected, @bitCast(u64, gdt_entries[2]));
    }
    {
        const expected: u64 = 0xAFFA000000FFFF;
        expectEqual(expected, @bitCast(u64, gdt_entries[3]));
    }
    {
        const expected: u64 = 0xAFF2000000FFFF;
        expectEqual(expected, @bitCast(u64, gdt_entries[4]));
    }
}

test "init" {
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("ltr", .{TSS_LOWER_OFFSET});

    arch.addConsumeFunction("lgdt", mock_lgdt);

    init();

    const tss_lower_entry = gdt_entries[TSS_INDEX_LOWER];
    const tss_upper_entry = gdt_entries[TSS_INDEX_UPPER];
    const tss_limit = @sizeOf(Tss) - 1;
    const tss_addr = @ptrToInt(&tss_entry);

    var expected_lower: u64 = 0;
    expected_lower |= @as(u64, @truncate(u16, tss_limit));
    expected_lower |= @as(u64, @truncate(u24, tss_addr)) << 16;
    expected_lower |= @as(u64, 0x89) << (16 + 24);
    expected_lower |= @as(u64, @truncate(u4, tss_limit >> 16)) << (16 + 24 + 8);
    // Flags are zero
    expected_lower |= @as(u64, @truncate(u8, tss_addr >> 24)) << (16 + 24 + 8 + 4 + 4);

    var expected_upper: u64 = 0;
    expected_upper |= @as(u64, @truncate(u16, tss_limit >> 48));
    expected_upper |= @as(u64, @truncate(u16, tss_limit >> 32));

    expectEqual(expected_lower, @bitCast(u64, tss_lower_entry));
    expectEqual(expected_upper, @bitCast(u64, tss_upper_entry));

    // Reset
    gdt_entries[TSS_INDEX_LOWER] = makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS);
    gdt_entries[TSS_INDEX_UPPER] = makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS);
}

///
/// Check that the GDT table was loaded properly by getting the previously loaded table and
/// compare the limit and base address.
///
fn rt_loadedGDTSuccess() void {
    const loaded_gdt = arch.sgdt();
    if (gdt_ptr.limit != loaded_gdt.limit) {
        panic(@errorReturnTrace(), "FAILURE: GDT not loaded properly: 0x{X} != 0x{X}\n", .{ gdt_ptr.limit, loaded_gdt.limit });
    }
    if (gdt_ptr.base != loaded_gdt.base) {
        panic(@errorReturnTrace(), "FAILURE: GDT not loaded properly: 0x{X} != {X}\n", .{ gdt_ptr.base, loaded_gdt.base });
    }
    log.info("Tested loading GDT\n", .{});
}

///
/// Run all the runtime tests.
///
pub fn runtimeTests() void {
    rt_loadedGDTSuccess();
}
