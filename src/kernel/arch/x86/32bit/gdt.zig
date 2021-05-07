const std = @import("std");
const expectEqual = std.testing.expectEqual;
const log = std.log.scoped(.x86_gdt);
const builtin = @import("builtin");
const is_test = builtin.is_test;
const panic = @import("../../../panic.zig").panic;
const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");

usingnamespace @import("../common/gdt.zig");

/// The TSS entry structure
const Tss = packed struct {
    /// Pointer to the previous TSS entry
    prev_tss: u16 = 0,
    reserved1: u16 = 0,

    /// Ring 0 32 bit stack pointer.
    esp0: u32 = 0,

    /// Ring 0 32 bit stack pointer.
    ss0: u16 = KERNEL_DATA_OFFSET,
    reserved2: u16 = 0,

    /// Ring 1 32 bit stack pointer.
    esp1: u32 = 0,

    /// Ring 1 32 bit stack pointer.
    ss1: u16 = 0,
    reserved3: u16 = 0,

    /// Ring 2 32 bit stack pointer.
    esp2: u32 = 0,

    /// Ring 2 32 bit stack pointer.
    ss2: u16 = 0,
    reserved4: u16 = 0,

    /// The CR3 control register 3.
    cr3: u32 = 0,

    /// 32 bit instruction pointer.
    eip: u32 = 0,

    /// 32 bit flags register.
    eflags: u32 = 0,

    /// 32 bit accumulator register.
    eax: u32 = 0,

    /// 32 bit counter register.
    ecx: u32 = 0,

    /// 32 bit data register.
    edx: u32 = 0,

    /// 32 bit base register.
    ebx: u32 = 0,

    /// 32 bit stack pointer register.
    esp: u32 = 0,

    /// 32 bit base pointer register.
    ebp: u32 = 0,

    /// 32 bit source register.
    esi: u32 = 0,

    /// 32 bit destination register.
    edi: u32 = 0,

    /// The extra segment.
    es: u16 = 0,
    reserved5: u16 = 0,

    /// The code segment.
    cs: u16 = 0,
    reserved6: u16 = 0,

    /// The stack segment.
    ss: u16 = 0,
    reserved7: u16 = 0,

    /// The data segment.
    ds: u16 = 0,
    reserved8: u16 = 0,

    /// A extra segment FS.
    fs: u16 = 0,
    reserved9: u16 = 0,

    /// A extra segment GS.
    gs: u16 = 0,
    reserved10: u16 = 0,

    /// The local descriptor table register.
    ldtr: u16 = 0,
    reserved11: u16 = 0,

    /// ?
    trap: u16 = 0,

    /// A pointer to a I/O port bitmap for the current task which specifies individual ports the program should have access to.
    io_permissions_base_offset: u16 = @sizeOf(Tss),
};

// Check the sizes of the packet structs.
comptime {
    std.debug.assert(@sizeOf(Tss) == 104);
}

/// The total number of entries in the GDT including: null, kernel code, kernel data, user code,
/// user data and the TSS.
const NUMBER_OF_ENTRIES: u16 = 0x06;

/// The size of the GTD in bytes (minus 1).
const TABLE_SIZE: u16 = @sizeOf(GdtEntry) * NUMBER_OF_ENTRIES - 1;

/// The index of the task state segment GDT entry.
const TSS_INDEX: u16 = 0x05;

/// The GDT pointer object used for loading the GDT entries.
const gdt_ptr: GdtPtr = GdtPtr{
    .limit = TABLE_SIZE,
    .base = &gdt_entries[0],
};

/// The main task state segment entry.
pub const main_tss_entry: Tss = Tss{};

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

/// The offset of the TTS GDT entry.
pub const TSS_OFFSET: u16 = 0x28;

/// The GDT entry table of NUMBER_OF_ENTRIES entries.
var gdt_entries: [NUMBER_OF_ENTRIES]GdtEntry = [_]GdtEntry{
    // Null descriptor
    makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS),

    // Kernel code descriptor
    makeGdtEntry(0, 0xFFFFF, KERNEL_SEGMENT_CODE, PAGING_32_BIT),

    // Kernel data descriptor
    makeGdtEntry(0, 0xFFFFF, KERNEL_SEGMENT_DATA, PAGING_32_BIT),

    // User code descriptor
    makeGdtEntry(0, 0xFFFFF, USER_SEGMENT_CODE, PAGING_32_BIT),

    // User data descriptor
    makeGdtEntry(0, 0xFFFFF, USER_SEGMENT_DATA, PAGING_32_BIT),

    // TSS descriptor, one each for each processor
    // Will initialise the TSS at runtime
    makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS),
};

///
/// Initialise the Global Descriptor table.
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    // Initiate TSS
    gdt_entries[TSS_INDEX] = makeGdtEntry(@ptrToInt(&main_tss_entry), @sizeOf(Tss) - 1, TSS_SEGMENT, NULL_FLAGS);

    // Load the GDT
    arch.lgdt(&gdt_ptr);

    // Load the TSS
    arch.ltr(TSS_OFFSET);

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
        const expected: u64 = 0xCF9A000000FFFF;
        expectEqual(expected, @bitCast(u64, gdt_entries[1]));
    }
    {
        const expected: u64 = 0xCF92000000FFFF;
        expectEqual(expected, @bitCast(u64, gdt_entries[2]));
    }
    {
        const expected: u64 = 0xCFFA000000FFFF;
        expectEqual(expected, @bitCast(u64, gdt_entries[3]));
    }
    {
        const expected: u64 = 0xCFF2000000FFFF;
        expectEqual(expected, @bitCast(u64, gdt_entries[4]));
    }
}

test "init" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("ltr", .{TSS_OFFSET});

    arch.addConsumeFunction("lgdt", mock_lgdt);

    // Call function
    init();

    // Post testing
    const tss_entry = gdt_entries[TSS_INDEX];
    const tss_limit = @sizeOf(Tss) - 1;
    const tss_addr = @ptrToInt(&main_tss_entry);

    var expected: u64 = 0;
    expected |= @as(u64, @truncate(u16, tss_limit));
    expected |= @as(u64, @truncate(u24, tss_addr)) << 16;
    expected |= @as(u64, 0x89) << (16 + 24);
    expected |= @as(u64, @truncate(u4, tss_limit >> 16)) << (16 + 24 + 8);
    // Flags are zero
    expected |= @as(u64, @truncate(u8, tss_addr >> 24)) << (16 + 24 + 8 + 4 + 4);

    expectEqual(expected, @bitCast(u64, tss_entry));

    // Reset
    gdt_entries[TSS_INDEX] = makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS);
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
