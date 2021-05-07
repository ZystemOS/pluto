const std = @import("std");
const expectEqual = std.testing.expectEqual;
const builtin = @import("builtin");

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
pub const GdtEntry = packed struct {
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
    std.debug.assert(@sizeOf(GdtPtr) == @sizeOf(usize) + @sizeOf(u16));
}

/// The null segment, everything is set to zero.
pub const NULL_SEGMENT: AccessBits = AccessBits{
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
pub const KERNEL_SEGMENT_CODE: AccessBits = AccessBits{
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
pub const KERNEL_SEGMENT_DATA: AccessBits = AccessBits{
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
pub const USER_SEGMENT_CODE: AccessBits = AccessBits{
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
pub const USER_SEGMENT_DATA: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 1,
    .privilege = 3,
    .present = 1,
};

/// This bit pattern represents a TSS segment with bits: accessed, executable and present set.
pub const TSS_SEGMENT: AccessBits = AccessBits{
    .accessed = 1,
    .read_write = 0,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 0,
    .privilege = 0,
    .present = 1,
};

/// The bit pattern for all bits set to zero.
pub const NULL_FLAGS: FlagBits = FlagBits{
    .reserved_zero = 0,
    .is_64_bit = 0,
    .is_32_bit = 0,
    .granularity = 0,
};

/// The bit pattern for all segments where we are in 32 bit protected mode and paging enabled.
pub const PAGING_32_BIT: FlagBits = FlagBits{
    .reserved_zero = 0,
    .is_64_bit = 0,
    .is_32_bit = 1,
    .granularity = 1,
};

/// The bit pattern for all segments where we are in 64 bit lone mode and paging granularity.
pub const PAGING_64_BIT: FlagBits = FlagBits{
    .reserved_zero = 0,
    .is_64_bit = 1,
    .is_32_bit = 0,
    .granularity = 1,
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
pub fn makeGdtEntry(base: u32, limit: u20, access: AccessBits, flags: FlagBits) GdtEntry {
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
