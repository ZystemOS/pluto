const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const vmm = if (is_test) @import(mock_path ++ "vmm_mock.zig") else @import("vmm.zig");
const panic = @import("panic.zig").panic;

const FreeListAllocator = struct {
    const Error = error{TooSmall};
    const Header = struct {
        size: usize,
        next_free: ?*Header,

        const Self = @Self();

        ///
        /// Initialise the header for a free allocation node
        ///
        /// Arguments:
        ///     IN size: usize - The node's size, not including the size of the header itself
        ///     IN next_free: ?*Header - A pointer to the next free node
        ///
        /// Return: Header
        ///     The header constructed
        fn init(size: usize, next_free: ?*Header) Header {
            return .{
                .size = size,
                .next_free = next_free,
            };
        }
    };

    first_free: ?*Header,
    allocator: Allocator,

    ///
    /// Initialise an empty and free FreeListAllocator
    ///
    /// Arguments:
    ///     IN start: usize - The starting address for all allocations
    ///     IN size: usize - The size of the region of memory to allocate within. Must be greater than @sizeOf(Header)
    ///
    /// Return: FreeListAllocator
    ///     The FreeListAllocator constructed
    ///
    /// Error: Error
    ///     Error.TooSmall - If size <= @sizeOf(Header)
    ///
    pub fn init(start: usize, size: usize) Error!FreeListAllocator {
        if (size <= @sizeOf(Header)) return Error.TooSmall;
        return FreeListAllocator{
            .first_free = insertFreeHeader(start, size - @sizeOf(Header), null),
            .allocator = .{
                .allocFn = alloc,
                .resizeFn = resize,
            },
        };
    }

    ///
    /// Create a free header at a specific location
    ///
    /// Arguments:
    ///     IN at: usize - The address to create it at
    ///     IN size: usize - The node's size, excluding the size of the header itself
    ///     IN next_free: ?*Header - The next free header in the allocator, or null if there isn't one
    ///
    /// Return *Header
    ///     The pointer to the header created
    ///
    fn insertFreeHeader(at: usize, size: usize, next_free: ?*Header) *Header {
        var node = @intToPtr(*Header, at);
        node.* = Header.init(size, next_free);
        return node;
    }

    ///
    /// Update the free header pointers that should point to the provided header
    ///
    /// Arguments:
    ///     IN self: *FreeListAllocator - The FreeListAllocator to modify
    ///     IN previous: ?*Header - The previous free node or null if there wasn't one. If null, self.first_free will be set to header, else previous.next_free will be set to header
    ///     IN header: ?*Header - The header being pointed to. This will be the new value of self.first_free or previous.next_free
    ///
    fn registerFreeHeader(self: *FreeListAllocator, previous: ?*Header, header: ?*Header) void {
        if (previous) |p| {
            p.next_free = header;
        } else {
            self.first_free = header;
        }
    }

    ///
    /// Free an allocation
    ///
    /// Arguments:
    ///     IN self: *FreeListAllocator - The allocator being freed within
    ///     IN mem: []u8 - The memory to free
    ///
    fn free(self: *FreeListAllocator, mem: []u8) void {
        const size = std.math.max(mem.len, @sizeOf(Header));
        const addr = @ptrToInt(mem.ptr);
        var header = insertFreeHeader(addr, size - @sizeOf(Header), null);
        if (self.first_free) |first| {
            var prev: ?*Header = null;
            // Find the previous free node
            if (@ptrToInt(first) < addr) {
                prev = first;
                while (prev.?.next_free) |next| {
                    if (@ptrToInt(next) > addr) break;
                    prev = next;
                }
            }
            // Make the freed header point to the next one, which is the one after the previous or the first if there was no previous
            header.next_free = if (prev) |p| p.next_free else first;

            self.registerFreeHeader(prev, header);

            // Join with the next one until the next isn't a neighbour
            if (header.next_free) |next| {
                if (@ptrToInt(next) == @ptrToInt(header) + header.size + @sizeOf(Header)) {
                    header.size += next.size + @sizeOf(Header);
                    header.next_free = next.next_free;
                }
            }

            // Try joining with the previous one
            if (prev) |p| {
                p.size += header.size + @sizeOf(Header);
                p.next_free = header.next_free;
            }
        } else {
            self.first_free = header;
        }
    }

    ///
    /// Attempt to resize an allocation. This should only be called via the Allocator interface.
    ///
    /// When the new size requested is 0, a free happens. See the free function for details.
    ///
    /// When the new size is greater than the old buffer's size, we attempt to steal some space from the neighbouring node.
    /// This can only be done if the neighbouring node is free and the remaining space after taking what is needed to resize is enough to create a new Header. This is because we don't want to leave any dangling memory that isn't tracked by a header.
    ///
    /// | <----- new_size ----->
    /// |---------|--------\----------------|
    /// |         |        \                |
    /// | old_mem | header \ header's space |
    /// |         |        \                |
    /// |---------|--------\----------------|
    ///
    /// After expanding to new_size, it will look like
    /// |-----------------------|--------\--|
    /// |                       |        \  |
    /// |        old_mem        | header \  |
    /// |                       |        \  |
    /// |-----------------------|--------\--|
    /// The free node before old_mem needs to then point to the new header rather than the old one and the new header needs to point to the free node after the old one. If there was no previous free node then the new one becomes the first free node.
    ///
    /// When the new size is smaller than the old_buffer's size, we attempt to shrink it and create a new header to the right.
    /// This can only be done if the space left by the shrinking is enough to create a new header, since we don't want to leave any dangling untracked memory.
    /// | <--- new_size --->
    /// |-----------------------------------|
    /// |                                   |
    /// |             old_mem               |
    /// |                                   |
    /// |-----------------------------------|
    ///
    /// After shrinking to new_size, it will look like
    /// | <--- new_size --->
    /// |-------------------|--------\-- ---|
    /// |                   |        \      |
    /// |      old_mem      | header \      |
    /// |                   |        \      |
    /// |-------------------|--------\------|
    /// We then attempt to join with neighbouring free nodes.
    /// The node before old_mem needs to then point to the new header and the new header needs to point to the next free node.
    ///
    /// Arguments:
    ///     IN allocator: *std.Allocator - The allocator to resize within.
    ///     IN old_mem: []u8 - The buffer to resize.
    ///     IN new_size: usize - What to resize to.
    ///     IN size_alignment: u29 - The alignment that the size should have.
    ///
    /// Return: usize
    ///     The new size of the buffer, which will be new_size if the operation was successful.
    ///
    /// Error: std.Allocator.Error
    ///     std.Allocator.Error.OutOfMemory - If there wasn't enough free memory to expand into
    ///
    fn resize(allocator: *Allocator, old_mem: []u8, new_size: usize, size_alignment: u29) Allocator.Error!usize {
        var self = @fieldParentPtr(FreeListAllocator, "allocator", allocator);
        if (new_size == 0) {
            self.free(old_mem);
            return 0;
        }
        if (new_size == old_mem.len) return new_size;

        const end = @ptrToInt(old_mem.ptr) + old_mem.len;
        var real_size = if (size_alignment > 1) std.mem.alignAllocLen(old_mem.len, new_size, size_alignment) else new_size;

        // Try to find the buffer's neighbour (if it's free) and the previous free node
        // We'll be stealing some of the free neighbour's space when expanding or joining up with it when shrinking
        var free_node = self.first_free;
        var next: ?*Header = null;
        var prev: ?*Header = null;
        while (free_node) |f| {
            if (@ptrToInt(f) == end) {
                // This free node is right next to the node being freed so is its neighbour
                next = f;
                break;
            } else if (@ptrToInt(f) > end) {
                // We've found a node past the node being freed so end early
                break;
            }
            prev = f;
            free_node = f.next_free;
        }

        // If we're expanding the buffer
        if (real_size > old_mem.len) {
            if (next) |n| {
                // If the free neighbour isn't big enough then fail
                if (old_mem.len + n.size + @sizeOf(Header) < real_size) return Allocator.Error.OutOfMemory;

                const size_diff = real_size - old_mem.len;
                const consumes_whole_neighbour = size_diff == n.size + @sizeOf(Header);
                // If the space left over in the free neighbour from the resize isn't enough to fit a new node, then fail
                if (!consumes_whole_neighbour and n.size + @sizeOf(Header) - size_diff < @sizeOf(Header)) return Allocator.Error.OutOfMemory;
                var new_next: ?*Header = n.next_free;
                // We don't do any splitting when consuming the whole neighbour
                if (!consumes_whole_neighbour) {
                    // Create the new header. It starts at the end of the buffer plus the stolen space
                    // The size will be the previous size minus what we stole
                    new_next = insertFreeHeader(end + size_diff, n.size - size_diff, n.next_free);
                }
                self.registerFreeHeader(prev, new_next);
                return real_size;
            }
            // The neighbour isn't free so we can't expand into it
            return Allocator.Error.OutOfMemory;
        } else {
            // Shrinking
            var size_diff = old_mem.len - real_size;
            // If shrinking would leave less space than required for a new header,
            // or if shrinking would make the buffer too small, don't shrink
            if (size_diff < @sizeOf(Header)) {
                return old_mem.len;
            }
            // Make sure the we have enough space for a header
            if (real_size < @sizeOf(Header)) {
                real_size = @sizeOf(Header);
            }

            // Create a new header for the space gained from shrinking
            var new_next = insertFreeHeader(@ptrToInt(old_mem.ptr) + real_size, size_diff - @sizeOf(Header), if (prev) |p| p.next_free else self.first_free);
            self.registerFreeHeader(prev, new_next);

            // Join with the neighbour
            if (next) |n| {
                new_next.size += n.size + @sizeOf(Header);
                new_next.next_free = n.next_free;
            }

            return real_size;
        }
    }

    ///
    /// Allocate a portion of memory. This should only be called via the Allocator interface.
    ///
    /// This will find the first free node within the heap that can fit the size requested. If the size of the node is larger than the requested size but any space left over isn't enough to create a new Header, the next node is tried. If the node would require some padding to reach the desired alignment and that padding wouldn't fit a new Header, the next node is tried (however this node is kept as a backup in case no future nodes can fit the request).
    ///
    /// |--------------\---------------------|
    /// |              \                     |
    /// | free header  \     free space      |
    /// |              \                     |
    /// |--------------\---------------------|
    ///
    /// When the alignment padding is large enough for a new Header, the node found is split on the left, like so
    /// <---- padding ---->
    /// |------------\-----|-------------\---|
    /// |            \     |             \   |
    /// | new header \     | free header \   |
    /// |            \     |             \   |
    /// |------------\-----|-------------\---|
    /// The previous free node should then point to the left split. The left split should point to the free node after the one that was found
    ///
    /// When the space left over in the free node is more than required for the allocation, it is split on the right
    /// |--------------\-------|------------\--|
    /// |              \       |            \  |
    /// | free header  \ space | new header \  |
    /// |              \       |            \  |
    /// |--------------\-------|------------\--|
    /// The previous free node should then point to the new node on the left and the new node should point to the next free node
    ///
    /// Splitting on the left and right can both happen in one allocation
    ///
    /// Arguments:
    ///     IN allocator: *std.Allocator - The allocator to use
    ///     IN size: usize - The amount of memory requested
    ///     IN alignment: u29 - The alignment that the address of the allocated memory should have
    ///     IN size_alignment: u29 - The alignment that the length of the allocated memory should have
    ///
    /// Return: []u8
    ///     The allocated memory
    ///
    /// Error: std.Allocator.Error
    ///     std.Allocator.Error.OutOfMemory - There wasn't enough memory left to fulfill the request
    ///
    pub fn alloc(allocator: *Allocator, size: usize, alignment: u29, size_alignment: u29) Allocator.Error![]u8 {
        var self = @fieldParentPtr(FreeListAllocator, "allocator", allocator);
        if (self.first_free == null) return Allocator.Error.OutOfMemory;

        // Get the real size being allocated, which is the aligned size or the size of a header (whichever is largest)
        // The size must be at least the size of a header so that it can be freed properly
        const real_size = std.math.max(if (size_alignment > 1) std.mem.alignAllocLen(size, size, size_alignment) else size, @sizeOf(Header));

        var free_header = self.first_free;
        var prev: ?*Header = null;
        var backup: ?*Header = null;
        var backup_prev: ?*Header = null;

        // Search for the first node that can fit the request
        const alloc_to = find: while (free_header) |h| : ({
            prev = h;
            free_header = h.next_free;
        }) {
            if (h.size + @sizeOf(Header) < real_size) {
                continue;
            }
            // The address at which to allocate. This will clobber the header.
            const addr = @ptrToInt(h);
            var alignment_padding: usize = 0;

            if ((alignment > 1 and !std.mem.isAligned(addr, alignment)) or !std.mem.isAligned(addr, @alignOf(Header))) {
                alignment_padding = alignment - (addr % alignment);
                // If the size can't fit the alignment padding then try the next one
                if (h.size + @sizeOf(Header) < real_size + alignment_padding) {
                    continue;
                }
                // If a new node couldn't be created from the space left by alignment padding then try the next one
                // This check is necessary as otherwise we'd have wasted space that could never be allocated
                // We do however set the backup variable to this node so that in the unfortunate case that no other nodes can take the allocation, we allocate it here and sacrifice the wasted space
                if (alignment_padding < @sizeOf(Header)) {
                    backup = h;
                    backup_prev = prev;
                    continue;
                }
            }

            // If we wouldn't be able to create a node with any unused space, try the next one
            // This check is necessary as otherwise we'd have wasted space that could never be allocated
            // Much like with the alignment padding, we set this node as a backup
            if (@sizeOf(Header) + h.size - alignment_padding - real_size < @sizeOf(Header)) {
                backup = h;
                backup_prev = prev;
                continue;
            }

            break :find h;
        } else backup;

        if (alloc_to == backup) {
            prev = backup_prev;
        }

        if (alloc_to) |x| {
            var header = x;
            var addr = @ptrToInt(header);
            // Allocate to this node
            var alignment_padding: usize = 0;
            if (alignment > 1 and !std.mem.isAligned(addr, alignment)) {
                alignment_padding = alignment - (addr % alignment);
            }

            // If there is enough unused space to the right of this node, need to align that pointer to the alignment of the header
            if (header.size > real_size + alignment_padding) {
                const at = @ptrToInt(header) + real_size + alignment_padding;
                if (!std.mem.isAligned(at, @alignOf(Header))) {
                    alignment_padding += @alignOf(Header) - (at % @alignOf(Header));
                }
            }

            // If we were going to use alignment padding and it's big enough to fit a new node, create a node to the left using the unused space
            if (alignment_padding >= @sizeOf(Header)) {
                // Since the header's address is going to be reused for the smaller one being created, backup the header to its new position
                header = insertFreeHeader(addr + alignment_padding, header.size - alignment_padding, header.next_free);

                var left = insertFreeHeader(addr, alignment_padding - @sizeOf(Header), header.next_free);
                // The previous should link to the new one instead
                self.registerFreeHeader(prev, left);
                prev = left;
                alignment_padding = 0;
            }

            // If there is enough unused space to the right of this node then create a smaller node
            if (header.size > real_size + alignment_padding) {
                header.next_free = insertFreeHeader(@ptrToInt(header) + real_size + alignment_padding, header.size - real_size - alignment_padding, header.next_free);
            }
            self.registerFreeHeader(prev, header.next_free);

            return @intToPtr([*]u8, @ptrToInt(header))[0..std.mem.alignAllocLen(size, size, size_alignment)];
        }

        return Allocator.Error.OutOfMemory;
    }

    test "init" {
        const size = 1024;
        var region = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(region);
        var free_list = &(try FreeListAllocator.init(@ptrToInt(region.ptr), size));

        var header = @intToPtr(*FreeListAllocator.Header, @ptrToInt(region.ptr));
        testing.expectEqual(header, free_list.first_free.?);
        testing.expectEqual(header.next_free, null);
        testing.expectEqual(header.size, size - @sizeOf(Header));

        testing.expectError(Error.TooSmall, FreeListAllocator.init(0, @sizeOf(Header) - 1));
    }

    test "alloc" {
        const size = 1024;
        var region = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(region);
        const start = @ptrToInt(region.ptr);
        var free_list = &(try FreeListAllocator.init(start, size));
        var allocator = &free_list.allocator;

        std.debug.warn("", .{});

        const alloc0 = try alloc(allocator, 64, 0, 0);
        const alloc0_addr = @ptrToInt(alloc0.ptr);
        // Should be at the start of the heap
        testing.expectEqual(alloc0_addr, start);
        // The allocation should have produced a node on the right of the allocation
        var header = @intToPtr(*Header, start + 64);
        testing.expectEqual(header.size, size - 64 - @sizeOf(Header));
        testing.expectEqual(header.next_free, null);
        testing.expectEqual(free_list.first_free, header);

        std.debug.warn("", .{});

        // 64 bytes aligned to 4 bytes
        const alloc1 = try alloc(allocator, 64, 4, 0);
        const alloc1_addr = @ptrToInt(alloc1.ptr);
        const alloc1_end = alloc1_addr + alloc1.len;
        // Should be to the right of the first allocation, with some alignment padding in between
        const alloc0_end = alloc0_addr + alloc0.len;
        testing.expect(alloc0_end <= alloc1_addr);
        testing.expectEqual(std.mem.alignForward(alloc0_end, 4), alloc1_addr);
        // It should have produced a node on the right
        header = @intToPtr(*Header, alloc1_end);
        testing.expectEqual(header.size, size - (alloc1_end - start) - @sizeOf(Header));
        testing.expectEqual(header.next_free, null);
        testing.expectEqual(free_list.first_free, header);

        const alloc2 = try alloc(allocator, 64, 256, 0);
        const alloc2_addr = @ptrToInt(alloc2.ptr);
        const alloc2_end = alloc2_addr + alloc2.len;
        testing.expect(alloc1_end < alloc2_addr);
        // There should be a free node to the right of alloc2
        const second_header = @intToPtr(*Header, alloc2_end);
        testing.expectEqual(second_header.size, size - (alloc2_end - start) - @sizeOf(Header));
        testing.expectEqual(second_header.next_free, null);
        // There should be a free node in between alloc1 and alloc2 due to the large alignment padding (depends on the allocation by the testing allocator, hence the check)
        if (alloc2_addr - alloc1_end >= @sizeOf(Header)) {
            header = @intToPtr(*Header, alloc1_end);
            testing.expectEqual(free_list.first_free, header);
            testing.expectEqual(header.next_free, second_header);
        }

        // Try allocating something smaller than @sizeOf(Header). This should scale up to @sizeOf(Header)
        var alloc3 = try alloc(allocator, 1, 0, 0);
        const alloc3_addr = @ptrToInt(alloc3.ptr);
        const alloc3_end = alloc3_addr + @sizeOf(Header);
        const header2 = @intToPtr(*Header, alloc3_end);
        // The new free node on the right should be the first one free
        testing.expectEqual(free_list.first_free, header2);
        // And it should point to the free node on the right of alloc2
        testing.expectEqual(header2.next_free, second_header);

        // Attempting to allocate more than the size of the largest free node should fail
        const remaining_size = second_header.size + @sizeOf(Header);
        testing.expectError(Allocator.Error.OutOfMemory, alloc(&free_list.allocator, remaining_size + 1, 0, 0));

        // Alloc a non aligned to header
        var alloc4 = try alloc(allocator, 13, 1, 0);
        const alloc4_addr = @ptrToInt(alloc4.ptr);
        const alloc4_end = alloc4_addr + std.mem.alignForward(13, @alignOf(Header));
        const header3 = @intToPtr(*Header, alloc4_end);
        const header4 = @intToPtr(*Header, alloc4_addr);

        // We should still have a length of 13
        testing.expectEqual(alloc4.len, 13);
        // But this should be aligned to Header (4)
        testing.expectEqual(alloc4_end - alloc4_addr, 16);

        // Previous header should now point to the next header
        testing.expectEqual(header2.next_free, header3);
    }

    test "free" {
        const size = 1024;
        var region = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(region);
        const start = @ptrToInt(region.ptr);
        var free_list = &(try FreeListAllocator.init(start, size));
        var allocator = &free_list.allocator;

        var alloc0 = try alloc(allocator, 128, 0, 0);
        var alloc1 = try alloc(allocator, 256, 0, 0);
        var alloc2 = try alloc(allocator, 64, 0, 0);

        // There should be a single free node after alloc2
        const free_node3 = @intToPtr(*Header, @ptrToInt(alloc2.ptr) + alloc2.len);
        testing.expectEqual(free_list.first_free, free_node3);
        testing.expectEqual(free_node3.size, size - alloc0.len - alloc1.len - alloc2.len - @sizeOf(Header));
        testing.expectEqual(free_node3.next_free, null);

        free_list.free(alloc0);
        // There should now be two free nodes. One where alloc0 was and another after alloc2
        const free_node0 = @intToPtr(*Header, start);
        testing.expectEqual(free_list.first_free, free_node0);
        testing.expectEqual(free_node0.size, alloc0.len - @sizeOf(Header));
        testing.expectEqual(free_node0.next_free, free_node3);

        // Freeing alloc1 should join it with free_node0
        free_list.free(alloc1);
        testing.expectEqual(free_list.first_free, free_node0);
        testing.expectEqual(free_node0.size, alloc0.len - @sizeOf(Header) + alloc1.len);
        testing.expectEqual(free_node0.next_free, free_node3);

        // Freeing alloc2 should then join them all together into one big free node
        free_list.free(alloc2);
        testing.expectEqual(free_list.first_free, free_node0);
        testing.expectEqual(free_node0.size, size - @sizeOf(Header));
        testing.expectEqual(free_node0.next_free, null);
    }

    test "resize" {
        std.debug.warn("", .{});
        const size = 1024;
        var region = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(region);
        const start = @ptrToInt(region.ptr);
        var free_list = &(try FreeListAllocator.init(start, size));
        var allocator = &free_list.allocator;

        var alloc0 = try alloc(allocator, 128, 0, 0);
        var alloc1 = try alloc(allocator, 256, 0, 0);

        // Expanding alloc0 should fail as alloc1 is right next to it
        testing.expectError(Allocator.Error.OutOfMemory, resize(&free_list.allocator, alloc0, 136, 0));

        // Expanding alloc1 should succeed
        testing.expectEqual(try resize(allocator, alloc1, 512, 0), 512);
        alloc1 = alloc1.ptr[0..512];
        // And there should be a free node on the right of it
        var header = @intToPtr(*Header, @ptrToInt(alloc1.ptr) + 512);
        testing.expectEqual(header.size, size - 128 - 512 - @sizeOf(Header));
        testing.expectEqual(header.next_free, null);
        testing.expectEqual(free_list.first_free, header);

        // Shrinking alloc1 should produce a big free node on the right
        testing.expectEqual(try resize(allocator, alloc1, 128, 0), 128);
        alloc1 = alloc1.ptr[0..128];
        header = @intToPtr(*Header, @ptrToInt(alloc1.ptr) + 128);
        testing.expectEqual(header.size, size - 128 - 128 - @sizeOf(Header));
        testing.expectEqual(header.next_free, null);
        testing.expectEqual(free_list.first_free, header);

        // Shrinking by less space than would allow for a new Header shouldn't work
        testing.expectEqual(resize(allocator, alloc1, alloc1.len - @sizeOf(Header) / 2, 0), 128);
        // Shrinking to less space than would allow for a new Header shouldn't work
        testing.expectEqual(resize(allocator, alloc1, @sizeOf(Header) / 2, 0), @sizeOf(Header));
    }
};

///
/// Initialise the kernel heap with a chosen allocator
///
/// Arguments:
///     IN vmm_payload: type - The payload passed around by the VMM. Decided by the architecture
///     IN heap_vmm: *vmm.VirtualMemoryManager - The VMM associated with the kernel
///     IN attributes: vmm.Attributes - The attributes to associate with the memory allocated for the heap
///     IN heap_size: usize - The desired size of the heap, in bytes. Must be greater than @sizeOf(FreeListAllocator.Header)
///
/// Return: FreeListAllocator
///     The FreeListAllocator created to keep track of the kernel heap
///
/// Error: FreeListAllocator.Error || Allocator.Error
///     FreeListAllocator.Error.TooSmall - heap_size is too small
///     Allocator.Error.OutOfMemory - heap_vmm's allocator didn't have enough memory available to fulfill the request
///
pub fn init(comptime vmm_payload: type, heap_vmm: *vmm.VirtualMemoryManager(vmm_payload), attributes: vmm.Attributes, heap_size: usize) (FreeListAllocator.Error || Allocator.Error)!FreeListAllocator {
    std.log.info(.heap, "Init\n", .{});
    defer std.log.info(.heap, "Done\n", .{});
    var heap_start = (try heap_vmm.alloc(heap_size / vmm.BLOCK_SIZE, attributes)) orelse panic(null, "Not enough contiguous virtual memory blocks to allocate to kernel heap\n", .{});
    // This free call cannot error as it is guaranteed to have been allocated above
    errdefer heap_vmm.free(heap_start) catch unreachable;
    return try FreeListAllocator.init(heap_start, heap_size);
}
