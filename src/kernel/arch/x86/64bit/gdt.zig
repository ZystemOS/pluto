const std = @import("std");

/// The TSS entry structure
pub const Tss = packed struct {
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

/// The 64 bit TSS entry.
pub const tss_entry: Tss = Tss{};
