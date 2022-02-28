const is_test = @import("builtin").is_test;
const std = @import("std");
const log = std.log.scoped(.pmm);
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const arch = @import("arch.zig").internals;
const MemProfile = @import("mem.zig").MemProfile;
const testing = std.testing;
const panic = @import("panic.zig").panic;
const Bitmap = @import("bitmap.zig").Bitmap;
const Allocator = std.mem.Allocator;

const PmmBitmap = Bitmap(u32);

/// The possible errors thrown by bitmap functions
const PmmError = error{
    /// The address given hasn't been allocated
    NotAllocated,
};

/// The size of memory associated with each bitmap entry
pub const BLOCK_SIZE: usize = arch.MEMORY_BLOCK_SIZE;

var bitmap: PmmBitmap = undefined;

///
/// Set the bitmap entry for an address as occupied
///
/// Arguments:
///     IN addr: usize - The address.
///
/// Error: PmmBitmap.BitmapError.
///     *: See PmmBitmap.setEntry. Could occur if the address is out of bounds.
///
pub fn setAddr(addr: usize) PmmBitmap.BitmapError!void {
    try bitmap.setEntry(@intCast(u32, addr / BLOCK_SIZE));
}

///
/// Check if an address is set as occupied.
///
/// Arguments:
///     IN addr: usize - The address to check.
///
/// Return: True if occupied, else false.
///
/// Error: PmmBitmap.BitmapError.
///     *: See PmmBitmap.setEntry. Could occur if the address is out of bounds.
///
pub fn isSet(addr: usize) PmmBitmap.BitmapError!bool {
    return bitmap.isSet(@intCast(u32, addr / BLOCK_SIZE));
}

///
/// Find the next free memory block, set it as occupied and return it. The region allocated will be of size BLOCK_SIZE.
///
/// Return: The address that was allocated.
///
pub fn alloc() ?usize {
    if (bitmap.setFirstFree()) |entry| {
        return entry * BLOCK_SIZE;
    }
    return null;
}

///
/// Set the address as free so it can be allocated in the future. This will free a block of size BLOCK_SIZE.
///
/// Arguments:
///     IN addr: usize - The previously allocated address to free. Will be aligned down to the nearest multiple of BLOCK_SIZE.
///
/// Error: PmmError || PmmBitmap.BitmapError.
///     PmmError.NotAllocated: The address wasn't allocated.
///     PmmBitmap.BitmapError.OutOfBounds: The address given was out of bounds.
///
pub fn free(addr: usize) (PmmBitmap.BitmapError || PmmError)!void {
    const idx = @intCast(u32, addr / BLOCK_SIZE);
    if (try bitmap.isSet(idx)) {
        try bitmap.clearEntry(idx);
    } else {
        return PmmError.NotAllocated;
    }
}

///
/// Get the number of unallocated blocks of memory.
///
/// Return: usize.
///     The number of unallocated blocks of memory
///
pub fn blocksFree() usize {
    return bitmap.num_free_entries;
}

/// Intiialise the physical memory manager and set all unavailable regions as occupied (those from the memory map and those from the linker symbols).
///
/// Arguments:
///     IN mem: *const MemProfile - The system's memory profile.
///     IN allocator: Allocator - The allocator to use to allocate the bitmaps.
///
pub fn init(mem_profile: *const MemProfile, allocator: Allocator) void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    bitmap = PmmBitmap.init(mem_profile.mem_kb * 1024 / BLOCK_SIZE, allocator) catch |e| {
        panic(@errorReturnTrace(), "Bitmap allocation failed: {}\n", .{e});
    };

    // Occupy the regions of memory that the memory map describes as reserved
    for (mem_profile.physical_reserved) |entry| {
        var addr = std.mem.alignBackward(entry.start, BLOCK_SIZE);
        var end = entry.end - 1;
        // If the end address can be aligned without overflowing then align it
        if (end <= std.math.maxInt(usize) - BLOCK_SIZE) {
            end = std.mem.alignForward(end, BLOCK_SIZE);
        }
        while (addr < end) : (addr += BLOCK_SIZE) {
            setAddr(addr) catch |e| switch (e) {
                // We can ignore out of bounds errors as the memory won't be available anyway
                PmmBitmap.BitmapError.OutOfBounds => break,
                else => panic(@errorReturnTrace(), "Failed setting address 0x{x} from memory map as occupied: {}", .{ addr, e }),
            };
        }
    }

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(mem_profile, allocator),
        else => {},
    }
}

///
/// Free the internal state of the PMM. Is unusable aftwards unless re-initialised
///
pub fn deinit() void {
    bitmap.deinit();
}

test "alloc" {
    bitmap = try Bitmap(u32).init(32, testing.allocator);
    defer bitmap.deinit();
    comptime var addr = 0;
    comptime var i = 0;
    // Allocate all entries, making sure they succeed and return the correct addresses
    inline while (i < 32) : ({
        i += 1;
        addr += BLOCK_SIZE;
    }) {
        try testing.expect(!(try isSet(addr)));
        try testing.expect(alloc().? == addr);
        try testing.expect(try isSet(addr));
        try testing.expectEqual(blocksFree(), 31 - i);
    }
    // Allocation should now fail
    try testing.expect(alloc() == null);
}

test "free" {
    bitmap = try Bitmap(u32).init(32, testing.allocator);
    defer bitmap.deinit();
    comptime var i = 0;
    // Allocate and free all entries
    inline while (i < 32) : (i += 1) {
        const addr = alloc().?;
        try testing.expect(try isSet(addr));
        try testing.expectEqual(blocksFree(), 31);
        try free(addr);
        try testing.expectEqual(blocksFree(), 32);
        try testing.expect(!(try isSet(addr)));
        // Double frees should be caught
        try testing.expectError(PmmError.NotAllocated, free(addr));
    }
}

test "setAddr and isSet" {
    const num_entries: u32 = 32;
    bitmap = try Bitmap(u32).init(num_entries, testing.allocator);
    defer bitmap.deinit();
    var addr: u32 = 0;
    var i: u32 = 0;
    while (i < num_entries) : ({
        i += 1;
        addr += BLOCK_SIZE;
    }) {
        // Ensure all previous blocks are still set
        var h: u32 = 0;
        var addr2: u32 = 0;
        while (h < i) : ({
            h += 1;
            addr2 += BLOCK_SIZE;
        }) {
            try testing.expect(try isSet(addr2));
        }

        try testing.expectEqual(blocksFree(), num_entries - i);
        // Set the current block
        try setAddr(addr);
        try testing.expect(try isSet(addr));
        try testing.expectEqual(blocksFree(), num_entries - i - 1);

        // Ensure all successive entries are not set
        var j: u32 = i + 1;
        var addr3: u32 = addr + BLOCK_SIZE;
        while (j < num_entries) : ({
            j += 1;
            addr3 += BLOCK_SIZE;
        }) {
            try testing.expect(!try isSet(addr3));
        }
    }
}

///
/// Allocate all blocks and make sure they don't overlap with any reserved addresses.
///
/// Arguments:
///     IN mem_profile: *const MemProfile - The memory profile to check for reserved memory regions.
///     IN/OUT allocator: Allocator - The allocator to use when needing to create intermediate structures used for testing
///
fn runtimeTests(mem_profile: *const MemProfile, allocator: Allocator) void {
    // Make sure that occupied memory can't be allocated
    var prev_alloc: usize = std.math.maxInt(usize);
    var alloc_list = std.ArrayList(usize).init(allocator);
    defer alloc_list.deinit();
    while (alloc()) |alloced| {
        if (prev_alloc == alloced) {
            panic(null, "FAILURE: PMM allocated the same address twice: 0x{x}", .{alloced});
        }
        prev_alloc = alloced;
        for (mem_profile.physical_reserved) |entry| {
            var addr = std.mem.alignBackward(@intCast(usize, entry.start), BLOCK_SIZE);
            if (addr == alloced) {
                panic(null, "FAILURE: PMM allocated an address that should be reserved by the memory map: 0x{x}", .{addr});
            }
        }
        alloc_list.append(alloced) catch |e| {
            panic(@errorReturnTrace(), "FAILURE: Failed to add PMM allocation to list: {}", .{e});
        };
    }
    // Clean up
    for (alloc_list.items) |alloced| {
        free(alloced) catch |e| {
            panic(@errorReturnTrace(), "FAILURE: Failed freeing allocation in PMM rt test: {}", .{e});
        };
    }
    log.info("Tested allocation\n", .{});
}
