const std = @import("std");
const expectEqual = std.testing.expectEqual;
const log = std.log.scoped(.x86_64_gdt);
const builtin = @import("builtin");
const is_test = builtin.is_test;
const panic = @import("../../panic.zig").panic;
const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");

/// The access bits for a GDT entry.
const AccessBits = packed struct {
    /// Whether the segment has been access. This shouldn't be set as it is set by the CPU when the
    /// segment is accessed.
    accessed: u1,

    /// For code segments, when set allows the code segment to be readable. Code segments are
    /// always executable. For data segments, when set allows the data segment to be writeable.
    /// Data segments are always readable.
    read_write: u1,

    /// For code segments, when set allows this code segments to be executed from a equal or lower
    /// privilege level. The privilege bits represent the highest privilege level that is allowed
    /// to execute this segment. If not set, then the code segment can only be executed from the
    /// same ring level specified in the privilege level bits. For data segments, when set the data
    /// segment grows downwards. When not set, the data segment grows upwards. So for both code and
    /// data segments, this shouldn't be set.
    direction_conforming: u1,

    /// When set, the segment can be executed, a code segments. When not set, the segment can't be
    /// executed, data segment.
    executable: u1,

    /// Should be set for code and data segments, but not set for TSS.
    descriptor: u1,

    /// Privilege/ring level. The kernel level is level 3, the highest privilege. The user level is
    /// level 0, the lowest privilege.
    privilege: u2,

    /// Whether the segment is present. This must be set for all valid selectors, not the null
    /// segment.
    present: u1,
};

/// The flag bits for a GDT entry.
const FlagBits = packed struct {
    /// The lowest bits must be 0 as this is reserved for future use.
    reserved_zero: u1,

    /// When set indicates the segment is a x86-64 segment. If set, then the IS_32_BIT flag must
    /// not be set. If both are set, then will throw an exception.
    is_64_bit: u1,

    /// When set indicates the segment is a 32 bit protected mode segment. When not set, indicates
    /// the segment is a 16 bit protected mode segment.
    is_32_bit: u1,

    /// The granularity bit. When set the limit is in 4KB blocks (page granularity). When not set,
    /// then limit is in 1B blocks (byte granularity). This should be set as we are doing paging.
    granularity: u1,
};

/// The structure that contains all the information that each GDT entry needs.
const GdtEntry = packed struct {
    /// The lower 16 bits of the limit address. Describes the size of memory that can be addressed.
    limit_low: u16,

    /// The lower 24 bits of the base address. Describes the start of memory for the entry.
    base_low: u24,

    /// The access bits, see AccessBits for all the options. 8 bits.
    access: AccessBits,

    /// The upper 4 bits of the limit address. Describes the size of memory that can be addressed.
    limit_high: u4,

    /// The flag bits, see above for all the options. 4 bits.
    flags: FlagBits,

    /// The upper 8 bits of the base address. Describes the start of memory for the entry.
    base_high: u8,
};

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

/// The GDT pointer structure that contains the pointer to the beginning of the GDT and the number
/// of the table (minus 1). Used to load the GDT with LGDT instruction.
pub const GdtPtr = packed struct {
    /// 16bit entry for the number of entries (minus 1).
    limit: u16,

    /// 64bit entry for the base address for the GDT.
    base: *const GdtEntry,
};

// Check the sizes of the packet structs.
comptime {
    std.debug.assert(@sizeOf(GdtEntry) == 8);
    std.debug.assert(@sizeOf(GdtPtr) == 10);
    std.debug.assert(@sizeOf(Tss) == 106);
}

/// The total number of entries in the GDT including: null, kernel code, kernel data, user code,
/// user data and the TSS.
const NUMBER_OF_ENTRIES: u16 = 0x07;

/// The size of the GTD in bytes (minus 1).
const TABLE_SIZE: u16 = @sizeOf(GdtEntry) * NUMBER_OF_ENTRIES - 1;

// ----------
// The indexes into the GDT where each segment resides.
// ----------

/// The index of the NULL GDT entry.
const NULL_INDEX: u16 = 0x00;

/// The index of the kernel code GDT entry.
const KERNEL_CODE_INDEX: u16 = 0x01;

/// The index of the kernel data GDT entry.
const KERNEL_DATA_INDEX: u16 = 0x02;

/// The index of the user code GDT entry.
const USER_CODE_INDEX: u16 = 0x03;

/// The index of the user data GDT entry.
const USER_DATA_INDEX: u16 = 0x04;

/// The index of the task state segment GDT entry. Lower 32 bit base address.
const TSS_INDEX_LOWER: u16 = 0x05;

/// The index of the task state segment GDT entry. Upper 32 bit base address.
const TSS_INDEX_UPPER: u16 = 0x06;

/// The null segment, everything is set to zero.
const NULL_SEGMENT: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 0,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 0,
    .privilege = 0,
    .present = 0,
};

/// This bit pattern represents a kernel code segment with bits: readable, executable, descriptor,
/// privilege 0, and present set.
const KERNEL_SEGMENT_CODE: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 1,
    .privilege = 0,
    .present = 1,
};

/// This bit pattern represents a kernel data segment with bits: writeable, descriptor, privilege 0,
/// and present set.
const KERNEL_SEGMENT_DATA: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 1,
    .privilege = 0,
    .present = 1,
};

/// This bit pattern represents a user code segment with bits: readable, executable, descriptor,
/// privilege 3, and present set.
const USER_SEGMENT_CODE: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 1,
    .privilege = 3,
    .present = 1,
};

/// This bit pattern represents a user data segment with bits: writeable, descriptor, privilege 3,
/// and present set.
const USER_SEGMENT_DATA: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 1,
    .privilege = 3,
    .present = 1,
};

/// This bit pattern represents a TSS segment with bits: accessed, executable and present set.
const TSS_SEGMENT: AccessBits = AccessBits{
    .accessed = 1,
    .read_write = 0,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 0,
    .privilege = 0,
    .present = 1,
};

/// The bit pattern for all bits set to zero.
const NULL_FLAGS: FlagBits = FlagBits{
    .reserved_zero = 0,
    .is_64_bit = 0,
    .is_32_bit = 0,
    .granularity = 0,
};

/// The bit pattern for all segments where we are in 64 bit lone mode and paging granularity.
const PAGING_64_BIT: FlagBits = FlagBits{
    .reserved_zero = 0,
    .is_64_bit = 1,
    .is_32_bit = 0,
    .granularity = 1,
};

/// The 64 bit TSS entry.
const tss_entry: Tss = Tss{};

/// The GDT pointer object used for loading the GDT entries.
const gdt_ptr: GdtPtr = GdtPtr{
    .limit = TABLE_SIZE,
    .base = &gdt_entries[0],
};

// ----------
// The offsets into the GDT where each segment resides.
// ----------

/// The offset of the NULL GDT entry.
pub const NULL_OFFSET: u16 = 0x00;

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
/// Make a GDT entry.
///
/// Arguments:
///     IN base: u32          - The linear address where the segment begins.
///     IN limit: u20         - The maximum addressable unit whether it is 1B units or page units.
///     IN access: AccessBits - The access bits for the descriptor.
///     IN flags: FlagBits    - The flag bits for the descriptor.
///
/// Return: GdtEntry
///     A new GDT entry with the give access and flag bits set with the base at 0x00000000 and
///     limit at 0xFFFFF.
///
fn makeGdtEntry(base: u32, limit: u20, access: AccessBits, flags: FlagBits) GdtEntry {
    return .{
        .limit_low = @truncate(u16, limit),
        .base_low = @truncate(u24, base),
        .access = .{
            .accessed = access.accessed,
            .read_write = access.read_write,
            .direction_conforming = access.direction_conforming,
            .executable = access.executable,
            .descriptor = access.descriptor,
            .privilege = access.privilege,
            .present = access.present,
        },
        .limit_high = @truncate(u4, limit >> 16),
        .flags = .{
            .reserved_zero = flags.reserved_zero,
            .is_64_bit = flags.is_64_bit,
            .is_32_bit = flags.is_32_bit,
            .granularity = flags.granularity,
        },
        .base_high = @truncate(u8, base >> 24),
    };
}

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

test "makeGdtEntry alternating bit pattern" {
    const alt_access = AccessBits{
        .accessed = 1,
        .read_write = 0,
        .direction_conforming = 1,
        .executable = 0,
        .descriptor = 1,
        .privilege = 0b10,
        .present = 0,
    };

    expectEqual(@as(u8, 0b01010101), @bitCast(u8, alt_access));

    const alt_flag = FlagBits{
        .reserved_zero = 1,
        .is_64_bit = 0,
        .is_32_bit = 1,
        .granularity = 0,
    };

    expectEqual(@as(u4, 0b0101), @bitCast(u4, alt_flag));

    const actual = makeGdtEntry(0b01010101010101010101010101010101, 0b01010101010101010101, alt_access, alt_flag);

    const expected: u64 = 0b0101010101010101010101010101010101010101010101010101010101010101;
    expectEqual(expected, @bitCast(u64, actual));
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
