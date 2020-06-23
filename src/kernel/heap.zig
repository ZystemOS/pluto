const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const is_test = builtin.is_test;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Bitmap = @import("bitmap.zig").Bitmap(usize);
const vmm = if (is_test) @import(mock_path ++ "vmm_mock.zig") else @import("vmm.zig");
const log = @import("log.zig");
const panic = @import("panic.zig").panic;

const Error = error{
    /// A value provided isn't a power of two
    NotPowerOfTwo,
    /// A pointer being freed hasn't been allocated or has already been freed
    NotAllocated,
};

/// A heap tracking occupied and free memory. This uses a buddy allocation system where memory is partitioned into blocks to fit an allocation request as suitably as possible.
/// If a block is greater than or the same as double the requested size it is halved, up until a minimum block size.
/// A bitmap is used to keep track of the allocated blocks with each bit corresponding to a partition of the minimum size.
const Heap = struct {
    /// The minimum block size
    block_min_size: u32,
    /// The start address of memory to allocate at
    start: usize,
    /// The size of the memory region to allocate within
    size: usize,
    /// Bitmap keeping track of allocated and unallocated blocks
    /// Each bit corresponds to a block of minimum size and is 1 if allocated else 0
    bitmap: Bitmap,
    allocator: Allocator,

    const Self = @This();

    /// The result of a heap search for a requested allocation
    const SearchResult = struct {
        /// The address found
        addr: usize,
        /// The number of heap entries occupied by an allocation request
        entries: usize,
        /// The entry associated with the start of the allocation
        entry: usize,
    };

    ///
    /// Initialise a new heap.
    ///
    /// Arguments:
    ///     IN start: usize - The start address of the memory region to allocate within
    ///     IN size: usize - The size of the memory region to allocate within. Must be greater than 0 and a power of two
    ///     IN block_min_size: u32 - The smallest possible block size. Smaller sizes give less wasted memory but increases the memory required by the heap itself
    ///     IN allocator: *std.mem.Allocator - The allocator used to create the data structures required by the heap. Not used after initialisation
    ///
    /// Return: Heap
    ///     The heap created.
    ///
    /// Error: std.mem.Allocator.Error || Heap.Error
    ///     Heap.Error.NotPowerOfTwo: Either block_min_size or size doesn't satisfy its constraints
    ///     std.mem.Allocator.Error.OutOfMemory: There wasn't enough free memory to allocate the heap's data structures.
    ///
    pub fn init(start: usize, size: usize, block_min_size: u32, allocator: *Allocator) (Allocator.Error || Error)!Heap {
        if (block_min_size == 0 or size == 0 or !std.math.isPowerOfTwo(size) or !std.math.isPowerOfTwo(block_min_size))
            return Error.NotPowerOfTwo;
        return Heap{
            .block_min_size = block_min_size,
            .start = start,
            .size = size,
            .bitmap = try Bitmap.init(@intCast(u32, size / block_min_size), allocator),
            .allocator = Allocator{
                .reallocFn = realloc,
                .shrinkFn = shrink,
            },
        };
    }

    /// See std/mem.zig for documentation. This function should only be called by the Allocator interface.
    fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
        var heap = @fieldParentPtr(Heap, "allocator", allocator);

        // If this is a new allocation
        if (old_mem.len == 0) {
            if (heap.alloc(new_size, new_align)) |addr| {
                return @intToPtr([*]u8, addr)[0..new_size];
            }
        }

        // Re-allocation to a smaller size/alignment is not currently supported
        return Allocator.Error.OutOfMemory;
    }

    /// See std/mem.zig for documentation. This function should only be called by the Allocator interface.
    fn shrink(allocator: *Allocator, old_mem: []u8, old_alignment: u29, new_size: usize, new_alignment: u29) []u8 {
        var heap = @fieldParentPtr(Heap, "allocator", allocator);
        if (new_size != old_mem.len) {
            // Freeing will error if the pointer was never allocated in the first place, but the Allocator API doesn't allow errors from shrink so use unreachable
            // It's not nice but is the only thing that can be done. Besides, if the unreachable is ever triggered then a double-free bug has been found
            heap.free(@ptrToInt(&old_mem[0]), old_mem.len) catch unreachable;
            if (new_size != 0) {
                // Try to re-allocate the memory to a better place
                // Alloc cannot error here as new_size is guaranteed to be <= old_mem.len and so freeing the old memory guarantees there is space for the new memory
                var new = @intToPtr([*]u8, heap.alloc(new_size, new_alignment) orelse unreachable)[0..new_size];
                std.mem.copy(u8, new, old_mem[0..new_size]);
                return new;
            }
        }
        return old_mem[0..new_size];
    }

    ///
    /// Search the entire heap for a block that can store the requested size and alignment.
    ///
    /// Arguments:
    ///     IN self: *Heap - The heap to search
    ///     IN addr: usize - The address associated with the block currently being searched
    ///     IN size: usize - The requested allocation size
    ///     IN order_size: usize - The size of the block being searched
    ///     IN alignment: ?u29 - The requested alignment or null if there wasn't one
    ///
    /// Return: ?SearchResult
    ///     The result of a successful search or null if the search failed
    ///
    fn search(self: *Self, addr: usize, size: usize, order_size: usize, alignment: ?u29) ?SearchResult {
        // If the requested size is greater than the order size then it can't fit here so return null
        if (size > order_size)
            return null;

        // If half of this block is bigger than the requested size and this block can be split then check each half
        if (order_size / 2 >= size and order_size > self.block_min_size) {
            if (self.search(addr, size, order_size / 2, alignment) orelse self.search(addr + order_size / 2, size, order_size / 2, alignment)) |e|
                return e;
        }

        // Fail if this entry's address is not aligned and alignment padding makes the allocation bigger than this order
        if (alignment) |al| {
            if (!std.mem.isAligned(addr, al) and size + (al - (addr % al)) > order_size)
                return null;
        }

        // Otherwise we must try to allocate at this block
        // Even if this block is made up of multiple entries, just checking if the first is free is sufficient to know the whole block is free
        const entry = (addr - self.start) / self.block_min_size;
        // isSet cannot error as the entry number will not be outside of the heap
        const is_free = !(self.bitmap.isSet(@intCast(u32, entry)) catch unreachable);
        if (is_free) {
            return SearchResult{
                .entry = entry,
                // The order size is guaranteed to be a power of 2 and multiple of the block size due to the checks in Heap.init, so no rounding is necessary
                .entries = order_size / self.block_min_size,
                .addr = if (alignment) |al| std.mem.alignForward(addr, al) else addr,
            };
        }
        return null;
    }

    ///
    /// Attempt to allocate a portion of memory within a heap. It is recommended to not call this directly and instead use the Allocator interface.
    ///
    /// Arguments:
    ///     IN/OUT self: *Heap - The heap to allocate within
    ///     IN size: usize - The size of the allocation
    ///     IN alignment: ?u29 - The alignment that the returned address should have, else null if no alignment is required
    ///
    /// Return: ?usize
    ///     The starting address of the allocation or null if there wasn't enough free memory.
    ///
    fn alloc(self: *Self, size: usize, alignment: ?u29) ?usize {
        if (size == 0 or size > self.size)
            return null;

        // The end of the allocation is marked with a 0 bit so search for the requested size plus one extra block for the 0
        if (self.search(self.start, size, self.size, alignment)) |result| {
            var i: u32 = 0;
            // Set the found entries as allocated
            while (i < result.entries) : (i += 1) {
                // Set the entry as allocated
                // Cannot error as the entry being set will not be outside of the heap
                self.bitmap.setEntry(@intCast(u32, result.entry + i)) catch unreachable;
            }
            return result.addr;
        }
        return null;
    }

    ///
    /// Free previously allocated memory. It is recommended to not call this directly and instead use the Allocator interface.
    ///
    /// Arguments:
    ///     IN/OUT self: *Heap - The heap to free within
    ///     IN ptr: usize - The address of the allocation to free. Should have been returned from a prior call to alloc.
    ///     IN len: usize - The size of the allocated region.
    ///
    /// Error: Heap.Error.
    ///     Heap.Error.NotAllocated: The address hasn't been allocated or is outside of the heap.
    ///
    fn free(self: *Self, ptr: usize, len: usize) Error!void {
        if (ptr < self.start or ptr + len > self.start + self.size)
            return Error.NotAllocated;

        const addr = ptr - self.start;
        const addr_end = addr + len;

        var addr_entry = @intCast(u32, addr / self.block_min_size);
        // Make sure the entry for this address has been allocated
        // Won't error as we've already checked the address is valid above
        if (!(self.bitmap.isSet(addr_entry) catch unreachable))
            return Error.NotAllocated;

        const NodeSearch = struct {
            start: usize,
            end: usize,

            const Self2 = @This();

            pub fn search(min: usize, max: usize, order_min: usize, order_max: usize) ?Self2 {
                if (min == order_min and max == order_max) {
                    return Self2{ .start = order_min, .end = order_max };
                }
                if (order_min > min or order_max < max) {
                    return null;
                }
                const order_size = order_max - order_min;
                if (search(min, max, order_min, order_min + order_size / 2) orelse search(min, max, order_max - order_size / 2, order_max)) |r| {
                    return r;
                }
                return Self2{ .start = order_min, .end = order_max };
            }
        };

        // Since the address could be aligned it may not fall on an allocation boundary, so it's necessary to traverse the tree to find the smallest node in which the address range fits
        // This will not be null as the address range is already guaranteed to be within the heap and so at least the root node will fit it
        const search_result = NodeSearch.search(addr, addr_end, 0, self.size) orelse unreachable;

        const entry_start = search_result.start / self.block_min_size;
        const entry_end = search_result.end / self.block_min_size + 1;

        // Clear entries associated with the order that the allocation was stored in
        var entry: u32 = @intCast(u32, entry_start);
        while (entry < entry_end and entry < self.size / self.block_min_size) : (entry += 1) {
            self.bitmap.clearEntry(entry) catch unreachable;
        }
    }
};

///
/// Initialise a heap to keep track of allocated memory.
///
/// Arguments:
///     IN vmm_payload: type - The virtual memory manager's payload type.
///     IN heap_vmm: vmm.VirtualMemoryManager(vmm_payload) - The virtual memory manager that will allocate a region of memory for the heap to govern.
///     IN attributes: vmm.Attributes - The attributes to apply to the heap's memory.
///     IN heap_size: usize - The size of the heap. Must be greater than zero, a power of two and should be a multiple of the vmm's block size.
///     IN allocator: *Allocator - The allocator to use to initialise the heap structure.
///
/// Return: Heap
///     The heap constructed.
///
/// Error: Allocator.Error || Error
///     Allocator.Error.OutOfMemory: There wasn't enough memory in the allocator to create the heap.
///     Heap.Error.NotPowerOfTwo: The heap size isn't a power of two or is 0.
///
pub fn init(comptime vmm_payload: type, heap_vmm: *vmm.VirtualMemoryManager(vmm_payload), attributes: vmm.Attributes, heap_size: usize, allocator: *Allocator) (Allocator.Error || Error)!Heap {
    log.logInfo("Init heap\n", .{});
    defer log.logInfo("Done heap\n", .{});
    var heap_start = (try heap_vmm.alloc(heap_size / vmm.BLOCK_SIZE, attributes)) orelse panic(null, "Not enough contiguous physical memory blocks to allocate to kernel heap\n", .{});
    // This free call cannot error as it is guaranteed to have been allocated above
    errdefer heap_vmm.free(heap_start) catch unreachable;
    return try Heap.init(heap_start, heap_size, 16, allocator);
}

test "init errors on non-power-of-two" {
    const start = 10;
    const allocator = std.heap.page_allocator;
    // Zero heap size
    testing.expectError(Error.NotPowerOfTwo, Heap.init(start, 0, 1024, allocator));
    // Non-power-of-size heap size
    testing.expectError(Error.NotPowerOfTwo, Heap.init(start, 100, 1024, allocator));
    // Non-power-of-two min block size
    testing.expectError(Error.NotPowerOfTwo, Heap.init(start, 1024, 100, allocator));
    // Non-power-of-two heap size and min block size
    testing.expectError(Error.NotPowerOfTwo, Heap.init(start, 100, 100, allocator));
    // Power-of-two heap size and min block size
    var heap = try Heap.init(start, 1024, 1024, allocator);
}

test "free detects unallocated addresses" {
    var heap = try Heap.init(10, 1024, 16, std.heap.page_allocator);
    // Before start of heap
    testing.expectError(Error.NotAllocated, heap.free(0, heap.block_min_size));
    // At start of heap
    testing.expectError(Error.NotAllocated, heap.free(heap.start, heap.block_min_size));
    // Within the heap
    testing.expectError(Error.NotAllocated, heap.free(21, heap.block_min_size));
    // End of heap
    testing.expectError(Error.NotAllocated, heap.free(heap.start + heap.size, heap.block_min_size));
    // Beyond heap
    testing.expectError(Error.NotAllocated, heap.free(heap.start + heap.size + 1, heap.block_min_size));
}

test "whole heap can be allocated and freed" {
    var heap = try Heap.init(0, 1024, 16, std.heap.page_allocator);
    var occupied: usize = 0;
    var rand = std.rand.DefaultPrng.init(123).random;

    // Allocate entire heap
    while (occupied < heap.size) {
        // This allocation should succeed
        const result = heap.alloc(heap.block_min_size, null) orelse unreachable;
        testing.expectEqual(occupied, result);
        occupied += heap.block_min_size;
    }
    // No more allocations should be possible
    testing.expectEqual(heap.alloc(1, null), null);

    // Try freeing all allocations
    while (occupied > 0) : (occupied -= heap.block_min_size) {
        const addr = occupied - heap.block_min_size;
        heap.free(addr, heap.block_min_size) catch unreachable;
        // Make sure it can be reallocated
        const result = heap.alloc(heap.block_min_size, null) orelse unreachable;
        testing.expectEqual(addr, result);
        // Re-free it
        heap.free(addr, heap.block_min_size) catch unreachable;
    }

    // Trying to free any previously allocated address should now fail
    var addr: usize = 0;
    while (addr < heap.size) : (addr += heap.block_min_size) {
        testing.expectError(Error.NotAllocated, heap.free(addr, heap.block_min_size));
    }

    // The bitmap should now be clear, otherwise free didn't clean up properly
    try testBitmapClear(&heap);
}

test "Allocator" {
    var buff = [_]u8{0} ** (4 * 1024 * 1024);
    var heap = try Heap.init(@ptrToInt(&buff), buff.len, 16, std.heap.page_allocator);
    var allocator = &heap.allocator;
    try testAllocator(allocator);
    try testAllocatorAligned(allocator, 32);
    try testAllocatorLargeAlignment(allocator);
}

fn testBitmapClear(heap: *Heap) !void {
    var entry: u32 = 0;
    while (entry < heap.bitmap.num_entries) : (entry += 1) {
        testing.expect(!(try heap.bitmap.isSet(entry)));
    }
}

// Copied from std.heap
fn testAllocator(allocator: *Allocator) !void {
    var slice = try allocator.alloc(*i32, 100);
    testing.expect(slice.len == 100);

    for (slice) |*item, i| {
        item.* = try allocator.create(i32);
        item.*.* = @intCast(i32, i);
    }

    for (slice) |item| {
        allocator.destroy(item);
    }

    slice = allocator.shrink(slice, 50);
    testing.expect(slice.len == 50);
    slice = allocator.shrink(slice, 25);
    testing.expect(slice.len == 25);
    slice = allocator.shrink(slice, 0);
    testing.expect(slice.len == 0);
    slice = try allocator.alloc(*i32, 10);
    testing.expect(slice.len == 10);

    allocator.free(slice);

    // The bitmap should now be clear, otherwise free didn't clean up properly
    testBitmapClear(@fieldParentPtr(Heap, "allocator", allocator)) catch unreachable;
}

// Copied from std.heap
fn testAllocatorAligned(allocator: *Allocator, comptime alignment: u29) !void {
    // initial
    var slice = try allocator.alignedAlloc(u8, alignment, 10);
    testing.expect(slice.len == 10);
    // Re-allocing isn't supported yet
    // grow
    //slice = try allocator.realloc(slice, 100);
    //testing.expect(slice.len == 100);
    // shrink
    slice = allocator.shrink(slice, 10);
    testing.expect(slice.len == 10);
    // go to zero
    slice = allocator.shrink(slice, 0);
    testing.expect(slice.len == 0);
    // realloc from zero
    // Re-allocing isn't supported yet
    //slice = try allocator.realloc(slice, 100);
    //testing.expect(slice.len == 100);
    // shrink with shrink
    //slice = allocator.shrink(slice, 10);
    //testing.expect(slice.len == 10);

    // shrink to zero
    slice = allocator.shrink(slice, 0);
    testing.expect(slice.len == 0);

    // The bitmap should now be clear, otherwise free didn't clean up properly
    testBitmapClear(@fieldParentPtr(Heap, "allocator", allocator)) catch unreachable;
}

// Copied from std.heap
fn testAllocatorLargeAlignment(allocator: *Allocator) Allocator.Error!void {
    //Maybe a platform's page_size is actually the same as or
    //  very near usize?
    if (std.mem.page_size << 2 > std.math.maxInt(usize)) return;

    const USizeShift = std.meta.IntType(false, std.math.log2(usize.bit_count));
    const large_align = @as(u29, std.mem.page_size << 2);

    var align_mask: usize = undefined;
    _ = @shlWithOverflow(usize, ~@as(usize, 0), @as(USizeShift, @ctz(u29, large_align)), &align_mask);

    var slice = try allocator.alignedAlloc(u8, large_align, 500);
    testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    slice = allocator.shrink(slice, 100);
    testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    // Re-allocating isn't supported yet
    //slice = try allocator.realloc(slice, 5000);
    //testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    slice = allocator.shrink(slice, 10);
    testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    // Re-allocating isn't supported yet
    //slice = try allocator.realloc(slice, 20000);
    //testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    allocator.free(slice);

    // The bitmap should now be clear, otherwise free didn't clean up properly
    testBitmapClear(@fieldParentPtr(Heap, "allocator", allocator)) catch unreachable;
}
