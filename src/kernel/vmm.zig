const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const builtin = @import("builtin");
const is_test = builtin.is_test;
const std = @import("std");
const bitmap = @import("bitmap.zig");
const pmm = @import("pmm.zig");
const mem = if (is_test) @import(mock_path ++ "mem_mock.zig") else @import("mem.zig");
const tty = @import("tty.zig");
const multiboot = @import("multiboot.zig");
const log = @import("log.zig");
const panic = @import("panic.zig").panic;
const arch = @import("arch.zig").internals;

/// Attributes for a virtual memory allocation
pub const Attributes = struct {
    /// Whether this memory belongs to the kernel and can therefore not be accessed in user mode
    kernel: bool,

    /// If this memory can be written to
    writable: bool,

    /// If this memory can be cached. Memory mapped to a device shouldn't, for example
    cachable: bool,
};

/// All data that must be remembered for a virtual memory allocation
const Allocation = struct {
    /// The physical blocks of memory associated with this allocation
    physical: std.ArrayList(usize),
};

/// The size of each allocatable block, the same as the physical memory manager's block size
pub const BLOCK_SIZE: usize = pmm.BLOCK_SIZE;

pub const MapperError = error{
    InvalidVirtualAddress,
    InvalidPhysicalAddress,
    AddressMismatch,
    MisalignedVirtualAddress,
    MisalignedPhysicalAddress,
    NotMapped,
};

///
/// Returns a container that can map and unmap virtual memory to physical memory.
/// The mapper can pass some payload data when mapping an unmapping, which is of type `Payload`. This can be anything that the underlying mapper needs to carry out the mapping process.
/// For x86, it would be the page directory that is being mapped within. An architecture or other mapper can specify the data it needs when mapping by specifying this type.
///
/// Arguments:
///     IN comptime Payload: type - The type of the VMM-specific payload to pass when mapping and unmapping
///
/// Return: type
///     The Mapper type constructed.
///
pub fn Mapper(comptime Payload: type) type {
    return struct {
        ///
        /// Map a region (can span more than one block) of virtual memory to physical memory. After a call to this function, the memory should be present the next time it is accessed.
        /// The attributes given must be obeyed when possible.
        ///
        /// Arguments:
        ///     IN virtual_start: usize - The start of the virtual memory to map
        ///     IN virtual_end: usize - The end of the virtual memory to map
        ///     IN physical_start: usize - The start of the physical memory to map to
        ///     IN physical_end: usize - The end of the physical memory to map to
        ///     IN attrs: Attributes - The attributes to apply to this region of memory
        ///     IN/OUT allocator: std.mem.Allocator - The allocator to use when mapping, if required
        ///     IN spec: Payload - The payload to pass to the mapper
        ///
        /// Error: std.mem.AllocatorError || MapperError
        ///     The causes depend on the mapper used
        ///
        mapFn: fn (virtual_start: usize, virtual_end: usize, physical_start: usize, physical_end: usize, attrs: Attributes, allocator: *std.mem.Allocator, spec: Payload) (std.mem.Allocator.Error || MapperError)!void,

        ///
        /// Unmap a region (can span more than one block) of virtual memory from its physical memory. After a call to this function, the memory should not be accessible without error.
        ///
        /// Arguments:
        ///     IN virtual_start: usize - The start of the virtual region to unmap
        ///     IN virtual_end: usize - The end of the virtual region to unmap
        ///     IN spec: Payload - The payload to pass to the mapper
        ///
        /// Error: std.mem.AllocatorError || MapperError
        ///     The causes depend on the mapper used
        ///
        unmapFn: fn (virtual_start: usize, virtual_end: usize, spec: Payload) (std.mem.Allocator.Error || MapperError)!void,
    };
}

/// Errors that can be returned by VMM functions
pub const VmmError = error{
    /// A memory region expected to be allocated wasn't
    NotAllocated,

    /// A memory region expected to not be allocated was
    AlreadyAllocated,

    /// A physical memory region expected to not be allocated was
    PhysicalAlreadyAllocated,

    /// A physical region of memory isn't of the same size as a virtual region
    PhysicalVirtualMismatch,

    /// Virtual addresses are invalid
    InvalidVirtAddresses,

    /// Physical addresses are invalid
    InvalidPhysAddresses,
};

///
/// Construct a virtual memory manager to keep track of allocated and free virtual memory regions within a certain space
///
/// Arguments:
///     IN comptime Payload: type - The type of the payload to pass to the mapper
///
/// Return: type
///     The constructed type
///
pub fn VirtualMemoryManager(comptime Payload: type) type {
    return struct {
        /// The bitmap that keeps track of allocated and free regions
        bmp: bitmap.Bitmap(usize),

        /// The start of the memory to be tracked
        start: usize,

        /// The end of the memory to be tracked
        end: usize,

        /// The allocator to use when allocating and freeing regions
        allocator: *std.mem.Allocator,

        /// All allocations that have been made with this manager
        allocations: std.hash_map.AutoHashMap(usize, Allocation),

        /// The mapper to use when allocating and freeing regions
        mapper: Mapper(Payload),

        /// The payload to pass to the mapper functions
        payload: Payload,

        const Self = @This();

        ///
        /// Initialise a virtual memory manager
        ///
        /// Arguments:
        ///     IN start: usize - The start of the memory region to manage
        ///     IN end: usize - The end of the memory region to manage. Must be greater than the start
        ///     IN/OUT allocator: *std.mem.Allocator - The allocator to use when allocating and freeing regions
        ///     IN mapper: Mapper - The mapper to use when allocating and freeing regions
        ///     IN payload: Payload - The payload data to be passed to the mapper
        ///
        /// Return: Self
        ///     The manager constructed
        ///
        /// Error: std.mem.Allocator.Error
        ///     std.mem.Allocator.Error.OutOfMemory - The allocator cannot allocate the memory required
        ///
        pub fn init(start: usize, end: usize, allocator: *std.mem.Allocator, mapper: Mapper(Payload), payload: Payload) std.mem.Allocator.Error!Self {
            const size = end - start;
            var bmp = try bitmap.Bitmap(usize).init(std.mem.alignForward(size, pmm.BLOCK_SIZE) / pmm.BLOCK_SIZE, allocator);
            return Self{
                .bmp = bmp,
                .start = start,
                .end = end,
                .allocator = allocator,
                .allocations = std.hash_map.AutoHashMap(usize, Allocation).init(allocator),
                .mapper = mapper,
                .payload = payload,
            };
        }

        ///
        /// Check if a virtual memory address has been set
        ///
        /// Arguments:
        ///     IN self: *Self - The manager to check
        ///     IN virt: usize - The virtual memory address to check
        ///
        /// Return: bool
        ///     Whether the address is set
        ///
        /// Error: pmm.PmmError
        ///     Bitmap(u32).Error.OutOfBounds - The address given is outside of the memory managed
        ///
        pub fn isSet(self: *const Self, virt: usize) bitmap.Bitmap(u32).BitmapError!bool {
            return try self.bmp.isSet(virt / BLOCK_SIZE);
        }

        ///
        /// Map a region (can span more than one block) of virtual memory to a specific region of memory
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The manager to modify
        ///     IN virtual_start: usize - The start of the virtual region
        ///     IN virtual_end: usize - The end of the virtual region
        ///     IN physical_start: usize - The start of the physical region
        ///     IN physical_end: usize - The end of the physical region
        ///     IN attrs: Attributes - The attributes to apply to the memory regions
        ///
        /// Error: VmmError || Bitmap(u32).BitmapError || std.mem.Allocator.Error || MapperError
        ///     VmmError.AlreadyAllocated - The virtual address has already been allocated
        ///     VmmError.PhysicalAlreadyAllocated - The physical address has already been allocated
        ///     VmmError.PhysicalVirtualMismatch - The physical region and virtual region are of different sizes
        ///     VmmError.InvalidVirtAddresses - The start virtual address is greater than the end address
        ///     VmmError.InvalidPhysicalAddresses - The start physical address is greater than the end address
        ///     Bitmap.BitmapError.OutOfBounds - The physical or virtual addresses are out of bounds
        ///     std.mem.Allocator.Error.OutOfMemory - Allocating the required memory failed
        ///     MapperError.* - The causes depend on the mapper used
        ///
        pub fn set(self: *Self, virtual_start: usize, virtual_end: usize, physical_start: usize, physical_end: usize, attrs: Attributes) (VmmError || bitmap.Bitmap(u32).BitmapError || std.mem.Allocator.Error || MapperError)!void {
            var virt = virtual_start;
            while (virt < virtual_end) : (virt += BLOCK_SIZE) {
                if (try self.isSet(virt))
                    return VmmError.AlreadyAllocated;
            }
            var phys = physical_start;
            while (phys < physical_end) : (phys += BLOCK_SIZE) {
                if (try pmm.isSet(phys))
                    return VmmError.PhysicalAlreadyAllocated;
            }
            if (virtual_end - virtual_start != physical_end - physical_start)
                return VmmError.PhysicalVirtualMismatch;
            if (physical_start > physical_end)
                return VmmError.InvalidPhysAddresses;
            if (virtual_start > virtual_end)
                return VmmError.InvalidVirtAddresses;

            virt = virtual_start;
            while (virt < virtual_end) : (virt += BLOCK_SIZE) {
                try self.bmp.setEntry(virt / BLOCK_SIZE);
            }

            try self.mapper.mapFn(virtual_start, virtual_end, physical_start, physical_end, attrs, self.allocator, self.payload);

            var phys_list = std.ArrayList(usize).init(self.allocator);
            phys = physical_start;
            while (phys < physical_end) : (phys += BLOCK_SIZE) {
                try pmm.setAddr(phys);
                try phys_list.append(phys);
            }
            _ = try self.allocations.put(virt, Allocation{ .physical = phys_list });
        }

        ///
        /// Allocate a number of contiguous blocks of virtual memory
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The manager to allocate for
        ///     IN num: usize - The number of blocks to allocate
        ///     IN attrs: Attributes - The attributes to apply to the mapped memory
        ///
        /// Return: ?usize
        ///     The address at the start of the allocated region, or null if no region could be allocated due to a lack of contiguous blocks.
        ///
        /// Error: std.mem.Allocator.Error
        ///     std.mem.AllocatorError.OutOfMemory: The required amount of memory couldn't be allocated
        ///
        pub fn alloc(self: *Self, num: usize, attrs: Attributes) std.mem.Allocator.Error!?usize {
            if (num == 0)
                return null;
            // Ensure that there is both enough physical and virtual address space free
            if (pmm.blocksFree() >= num and self.bmp.num_free_entries >= num) {
                // The virtual address space must be contiguous
                if (self.bmp.setContiguous(num)) |entry| {
                    var block_list = std.ArrayList(usize).init(self.allocator);
                    try block_list.ensureCapacity(num);

                    var i: usize = 0;
                    const vaddr_start = self.start + entry * BLOCK_SIZE;
                    var vaddr = vaddr_start;
                    // Map the blocks to physical memory
                    while (i < num) : (i += 1) {
                        const addr = pmm.alloc() orelse unreachable;
                        try block_list.append(addr);
                        // The map function failing isn't the caller's responsibility so panic as it shouldn't happen
                        self.mapper.mapFn(vaddr, vaddr + BLOCK_SIZE, addr, addr + BLOCK_SIZE, attrs, self.allocator, self.payload) catch |e| panic(@errorReturnTrace(), "Failed to map virtual memory: {}\n", .{e});
                        vaddr += BLOCK_SIZE;
                    }
                    _ = try self.allocations.put(vaddr_start, Allocation{ .physical = block_list });
                    return vaddr_start;
                }
            }
            return null;
        }

        ///
        /// Free a previous allocation
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The manager to free within
        ///     IN vaddr: usize - The start of the allocation to free. This should be the address returned from a prior `alloc` call
        ///
        /// Error: Bitmap.BitmapError || VmmError
        ///     VmmError.NotAllocated - This address hasn't been allocated yet
        ///     Bitmap.BitmapError.OutOfBounds - The address is out of the manager's bounds
        ///
        pub fn free(self: *Self, vaddr: usize) (bitmap.Bitmap(u32).BitmapError || VmmError)!void {
            const entry = vaddr / BLOCK_SIZE;
            if (try self.bmp.isSet(entry)) {
                // There will be an allocation associated with this virtual address
                const allocation = self.allocations.get(vaddr) orelse unreachable;
                const physical = allocation.value.physical;
                defer physical.deinit();
                const num_physical_allocations = physical.items.len;
                for (physical.items) |block, i| {
                    // Clear the address space entry, unmap the virtual memory and free the physical memory
                    try self.bmp.clearEntry(entry + i);
                    pmm.free(block) catch |e| panic(@errorReturnTrace(), "Failed to free PMM reserved memory at 0x{X}: {}\n", .{ block * BLOCK_SIZE, e });
                }
                // Unmap the entire range
                const region_start = entry * BLOCK_SIZE;
                const region_end = (entry + num_physical_allocations) * BLOCK_SIZE;
                self.mapper.unmapFn(region_start, region_end, self.payload) catch |e| panic(@errorReturnTrace(), "Failed to unmap VMM reserved memory from 0x{X} to 0x{X}: {}\n", .{ region_start, region_end, e });
                // The allocation is freed so remove from the map
                self.allocations.removeAssertDiscard(vaddr);
            } else {
                return VmmError.NotAllocated;
            }
        }
    };
}

///
/// Initialise the main system virtual memory manager covering 4GB. Maps in the kernel code, TTY, multiboot info and boot modules
///
/// Arguments:
///     IN mem_profile: *const mem.MemProfile - The system's memory profile. This is used to find the kernel code region and boot modules
///     IN mb_info: *multiboot.multiboot_info_t - The multiboot info
///     IN/OUT allocator: *std.mem.Allocator - The allocator to use when needing to allocate memory
///     IN comptime Payload: type - The type of the data to pass as a payload to the virtual memory manager
///     IN mapper: Mapper - The memory mapper to call when allocating and free virtual memory
///     IN payload: Payload - The payload data to pass to the virtual memory manager
///
/// Return: VirtualMemoryManager
///     The virtual memory manager created with all stated regions allocated
///
/// Error: std.mem.Allocator.Error
///     std.mem.Allocator.Error.OutOfMemory - The allocator cannot allocate the memory required
///
pub fn init(mem_profile: *const mem.MemProfile, mb_info: *multiboot.multiboot_info_t, allocator: *std.mem.Allocator) std.mem.Allocator.Error!VirtualMemoryManager(arch.VmmPayload) {
    log.logInfo("Init vmm\n", .{});
    defer log.logInfo("Done vmm\n", .{});

    var vmm = try VirtualMemoryManager(arch.VmmPayload).init(BLOCK_SIZE, 0xFFFFFFFF, allocator, arch.VMM_MAPPER, arch.KERNEL_VMM_PAYLOAD);

    // Map in kernel
    // Calculate start and end of mapping
    const v_start = std.mem.alignBackward(@ptrToInt(mem_profile.vaddr_start), BLOCK_SIZE);
    const v_end = std.mem.alignForward(@ptrToInt(mem_profile.vaddr_end) + mem_profile.fixed_alloc_size, BLOCK_SIZE);
    const p_start = std.mem.alignBackward(@ptrToInt(mem_profile.physaddr_start), BLOCK_SIZE);
    const p_end = std.mem.alignForward(@ptrToInt(mem_profile.physaddr_end) + mem_profile.fixed_alloc_size, BLOCK_SIZE);
    vmm.set(v_start, v_end, p_start, p_end, .{ .kernel = true, .writable = false, .cachable = true }) catch |e| panic(@errorReturnTrace(), "Failed mapping kernel code in VMM: {}", .{e});

    // Map in tty
    const tty_addr = tty.getVideoBufferAddress();
    const tty_phys = mem.virtToPhys(tty_addr);
    const tty_buff_size = 32 * 1024;
    vmm.set(tty_addr, tty_addr + tty_buff_size, tty_phys, tty_phys + tty_buff_size, .{ .kernel = true, .writable = true, .cachable = true }) catch |e| panic(@errorReturnTrace(), "Failed mapping TTY in VMM: {}", .{e});

    // Map in the multiboot info struct
    const mb_info_addr = std.mem.alignBackward(@ptrToInt(mb_info), BLOCK_SIZE);
    const mb_info_end = std.mem.alignForward(mb_info_addr + @sizeOf(multiboot.multiboot_info_t), BLOCK_SIZE);
    vmm.set(mb_info_addr, mb_info_end, mem.virtToPhys(mb_info_addr), mem.virtToPhys(mb_info_end), .{ .kernel = true, .writable = false, .cachable = true }) catch |e| panic(@errorReturnTrace(), "Failed mapping multiboot info in VMM: {}", .{e});

    // Map in each boot module
    for (mem_profile.boot_modules) |*module| {
        const mod_v_struct_start = std.mem.alignBackward(@ptrToInt(module), BLOCK_SIZE);
        const mod_v_struct_end = std.mem.alignForward(mod_v_struct_start + @sizeOf(multiboot.multiboot_module_t), BLOCK_SIZE);
        vmm.set(mod_v_struct_start, mod_v_struct_end, mem.virtToPhys(mod_v_struct_start), mem.virtToPhys(mod_v_struct_end), .{ .kernel = true, .writable = true, .cachable = true }) catch |e| switch (e) {
            // A previous allocation could cover this region so the AlreadyAllocated error can be ignored
            VmmError.AlreadyAllocated => break,
            else => panic(@errorReturnTrace(), "Failed mapping boot module struct in VMM: {}", .{e}),
        };
        const mod_p_start = std.mem.alignBackward(module.mod_start, BLOCK_SIZE);
        const mod_p_end = std.mem.alignForward(module.mod_end, BLOCK_SIZE);
        vmm.set(mem.physToVirt(mod_p_start), mem.physToVirt(mod_p_end), mod_p_start, mod_p_end, .{ .kernel = true, .writable = true, .cachable = true }) catch |e| panic(@errorReturnTrace(), "Failed mapping boot module in VMM: {}", .{e});
    }

    switch (build_options.test_type) {
        .NORMAL => runtimeTests(arch.VmmPayload, vmm, mem_profile, mb_info),
        else => {},
    }
    return vmm;
}

test "alloc and free" {
    const num_entries = 512;
    var vmm = try testInit(num_entries);
    var allocations = test_allocations orelse unreachable;
    var virtual_allocations = std.ArrayList(usize).init(std.testing.allocator);
    defer virtual_allocations.deinit();

    var entry: u32 = 0;
    while (entry < num_entries) {
        // Test allocating various numbers of blocks all at once
        // Rather than using a random number generator, just set the number of blocks to allocate based on how many entries have been done so far
        var num_to_alloc: u32 = if (entry > 400) @as(u32, 8) else if (entry > 320) @as(u32, 14) else if (entry > 270) @as(u32, 9) else if (entry > 150) @as(u32, 26) else @as(u32, 1);
        const result = try vmm.alloc(num_to_alloc, .{ .kernel = true, .writable = true, .cachable = true });

        var should_be_set = true;
        if (entry + num_to_alloc > num_entries) {
            // If the number to allocate exceeded the number of entries, then allocation should have failed
            std.testing.expectEqual(@as(?usize, null), result);
            should_be_set = false;
        } else {
            // Else it should have succeeded and allocated the correct address
            std.testing.expectEqual(@as(?usize, vmm.start + entry * BLOCK_SIZE), result);
            try virtual_allocations.append(result orelse unreachable);
        }

        // Make sure that the entries are set or not depending on the allocation success
        var vaddr = entry * BLOCK_SIZE;
        while (vaddr < (entry + num_to_alloc) * BLOCK_SIZE) : (vaddr += BLOCK_SIZE) {
            if (should_be_set) {
                // Allocation succeeded so this address should be set
                std.testing.expect(try vmm.isSet(vaddr));
                // The test mapper should have received this address
                std.testing.expect(try allocations.isSet(vaddr / BLOCK_SIZE));
            } else {
                // Allocation failed as there weren't enough free entries
                if (vaddr >= num_entries * BLOCK_SIZE) {
                    // If this address is beyond the VMM's end address, it should be out of bounds
                    std.testing.expectError(bitmap.Bitmap(u32).BitmapError.OutOfBounds, vmm.isSet(vaddr));
                    std.testing.expectError(bitmap.Bitmap(u64).BitmapError.OutOfBounds, allocations.isSet(vaddr / BLOCK_SIZE));
                } else {
                    // Else it should not be set
                    std.testing.expect(!(try vmm.isSet(vaddr)));
                    // The test mapper should not have received this address
                    std.testing.expect(!(try allocations.isSet(vaddr / BLOCK_SIZE)));
                }
            }
        }
        entry += num_to_alloc;

        // All later entries should not be set
        var later_entry = entry;
        while (later_entry < num_entries) : (later_entry += 1) {
            std.testing.expect(!(try vmm.isSet(vmm.start + later_entry * BLOCK_SIZE)));
            std.testing.expect(!(try pmm.isSet(later_entry * BLOCK_SIZE)));
        }
    }

    // Try freeing all allocations
    for (virtual_allocations.items) |alloc| {
        const alloc_group = vmm.allocations.get(alloc);
        std.testing.expect(alloc_group != null);
        const physical = alloc_group.?.value.physical;
        // We need to create a copy of the physical allocations since the free call deinits them
        var physical_copy = std.ArrayList(usize).init(std.testing.allocator);
        defer physical_copy.deinit();
        // Make sure they are all reserved in the PMM
        for (physical.items) |phys| {
            std.testing.expect(try pmm.isSet(phys));
            try physical_copy.append(phys);
        }
        vmm.free(alloc) catch unreachable;
        // This virtual allocation should no longer be in the hashmap
        std.testing.expectEqual(vmm.allocations.get(alloc), null);
        std.testing.expect(!try vmm.isSet(alloc));
        // And all its physical blocks should now be free
        for (physical_copy.items) |phys| {
            std.testing.expect(!try pmm.isSet(phys));
        }
    }
}

test "set" {
    const num_entries = 512;
    var vmm = try testInit(num_entries);

    const vstart = BLOCK_SIZE * 37;
    const vend = BLOCK_SIZE * 46;
    const pstart = vstart + 123;
    const pend = vend + 123;
    const attrs = Attributes{ .kernel = true, .writable = true, .cachable = true };
    try vmm.set(vstart, vend, pstart, pend, attrs);

    var allocations = test_allocations orelse unreachable;
    // The entries before the virtual start shouldn't be set
    var vaddr = vmm.start;
    while (vaddr < vstart) : (vaddr += BLOCK_SIZE) {
        std.testing.expect(!(try allocations.isSet(vaddr / BLOCK_SIZE)));
    }
    // The entries up until the virtual end should be set
    while (vaddr < vend) : (vaddr += BLOCK_SIZE) {
        std.testing.expect(try allocations.isSet(vaddr / BLOCK_SIZE));
    }
    // The entries after the virtual end should not be set
    while (vaddr < vmm.end) : (vaddr += BLOCK_SIZE) {
        std.testing.expect(!(try allocations.isSet(vaddr / BLOCK_SIZE)));
    }
}

var test_allocations: ?bitmap.Bitmap(u64) = null;
var test_mapper = Mapper(u8){ .mapFn = testMap, .unmapFn = testUnmap };

///
/// Initialise a virtual memory manager used for testing
///
/// Arguments:
///     IN num_entries: u32 - The number of entries the VMM should track
///
/// Return: VirtualMemoryManager(u8)
///     The VMM constructed
///
/// Error: std.mem.Allocator.Error
///     OutOfMemory: The allocator couldn't allocate the structures needed
///
fn testInit(num_entries: u32) std.mem.Allocator.Error!VirtualMemoryManager(u8) {
    if (test_allocations == null) {
        test_allocations = try bitmap.Bitmap(u64).init(num_entries, std.heap.page_allocator);
    } else |allocations| {
        var entry: u32 = 0;
        while (entry < allocations.num_entries) : (entry += 1) {
            allocations.clearEntry(entry) catch unreachable;
        }
    }
    var allocations = test_allocations orelse unreachable;
    const mem_profile = mem.MemProfile{ .vaddr_end = undefined, .vaddr_start = undefined, .physaddr_start = undefined, .physaddr_end = undefined, .mem_kb = num_entries * BLOCK_SIZE / 1024, .fixed_alloc_size = undefined, .mem_map = &[_]multiboot.multiboot_memory_map_t{}, .boot_modules = &[_]multiboot.multiboot_module_t{} };
    pmm.init(&mem_profile, std.heap.page_allocator);
    return try VirtualMemoryManager(u8).init(0, num_entries * BLOCK_SIZE, std.heap.page_allocator, test_mapper, 39);
}

///
/// A mapping function used when doing unit tests
///
/// Arguments:
///     IN vstart: usize - The start of the virtual region to map
///     IN vend: usize - The end of the virtual region to map
///     IN pstart: usize - The start of the physical region to map
///     IN pend: usize - The end of the physical region to map
///     IN attrs: Attributes - The attributes to map with
///     IN/OUT allocator: *std.mem.Allocator - The allocator to use. Ignored
///     IN payload: u8 - The payload value. Expected to be 39
///
fn testMap(vstart: usize, vend: usize, pstart: usize, pend: usize, attrs: Attributes, allocator: *std.mem.Allocator, payload: u8) (std.mem.Allocator.Error || MapperError)!void {
    std.testing.expectEqual(@as(u8, 39), payload);
    var vaddr = vstart;
    while (vaddr < vend) : (vaddr += BLOCK_SIZE) {
        (test_allocations orelse unreachable).setEntry(vaddr / BLOCK_SIZE) catch unreachable;
    }
}

///
/// An unmapping function used when doing unit tests
///
/// Arguments:
///     IN vstart: usize - The start of the virtual region to unmap
///     IN vend: usize - The end of the virtual region to unmap
///     IN payload: u8 - The payload value. Expected to be 39
///
fn testUnmap(vstart: usize, vend: usize, payload: u8) (std.mem.Allocator.Error || MapperError)!void {
    std.testing.expectEqual(@as(u8, 39), payload);
    var vaddr = vstart;
    while (vaddr < vend) : (vaddr += BLOCK_SIZE) {
        (test_allocations orelse unreachable).clearEntry(vaddr / BLOCK_SIZE) catch unreachable;
    }
}

///
/// Run the runtime tests.
///
/// Arguments:
///     IN comptime Payload: type - The type of the payload passed to the mapper
///     IN vmm: VirtualMemoryManager(Payload) - The virtual memory manager to test
///     IN mem_profile: *const mem.MemProfile - The mem profile with details about all the memory regions that should be reserved
///     IN mb_info: *multiboot.multiboot_info_t - The multiboot info struct that should also be reserved
///
fn runtimeTests(comptime Payload: type, vmm: VirtualMemoryManager(Payload), mem_profile: *const mem.MemProfile, mb_info: *multiboot.multiboot_info_t) void {
    const v_start = std.mem.alignBackward(@ptrToInt(mem_profile.vaddr_start), BLOCK_SIZE);
    const v_end = std.mem.alignForward(@ptrToInt(mem_profile.vaddr_end) + mem_profile.fixed_alloc_size, BLOCK_SIZE);
    const p_start = std.mem.alignBackward(@ptrToInt(mem_profile.physaddr_start), BLOCK_SIZE);
    const p_end = std.mem.alignForward(@ptrToInt(mem_profile.physaddr_end) + mem_profile.fixed_alloc_size, BLOCK_SIZE);
    const tty_addr = tty.getVideoBufferAddress();
    const tty_phys = mem.virtToPhys(tty_addr);
    const tty_buff_size = 32 * 1024;
    const mb_info_addr = std.mem.alignBackward(@ptrToInt(mb_info), BLOCK_SIZE);
    const mb_info_end = std.mem.alignForward(mb_info_addr + @sizeOf(multiboot.multiboot_info_t), BLOCK_SIZE);

    // Make sure all blocks before the mb info are not set
    var vaddr = vmm.start;
    while (vaddr < mb_info_addr) : (vaddr += BLOCK_SIZE) {
        const set = vmm.isSet(vaddr) catch |e| panic(@errorReturnTrace(), "FAILURE: Failed to check if mb_info address 0x{X} is set: {}}n", .{ vaddr, e });
        if (set) panic(null, "FAILURE: Address before mb_info was set: 0x{X}\n", .{vaddr});
    }
    // Make sure all blocks associated with the mb info are set
    while (vaddr < mb_info_end) : (vaddr += BLOCK_SIZE) {
        const set = vmm.isSet(vaddr) catch |e| panic(@errorReturnTrace(), "FAILURE: Failed to check if mb_info address {x} is set: {}\n", .{ vaddr, e });
        if (!set) panic(null, "FAILURE: Address for mb_info was not set: 0x{X}\n", .{vaddr});
    }

    // Make sure all blocks before the kernel code are not set
    while (vaddr < tty_addr) : (vaddr += BLOCK_SIZE) {
        const set = vmm.isSet(vaddr) catch |e| panic(@errorReturnTrace(), "FAILURE: Failed to check if tty address 0x{X} is set: {}\n", .{ vaddr, e });
        if (set) panic(null, "FAILURE: Address before tty was set: 0x{X}\n", .{vaddr});
    }
    // Make sure all blocks associated with the kernel code are set
    while (vaddr < tty_addr + tty_buff_size) : (vaddr += BLOCK_SIZE) {
        const set = vmm.isSet(vaddr) catch |e| panic(@errorReturnTrace(), "FAILURE: Failed to check if tty address 0x{X} is set: {}\n", .{ vaddr, e });
        if (!set) panic(null, "FAILURE: Address for tty was not set: 0x{X}\n", .{vaddr});
    }

    // Make sure all blocks before the kernel code are not set
    while (vaddr < v_start) : (vaddr += BLOCK_SIZE) {
        const set = vmm.isSet(vaddr) catch |e| panic(@errorReturnTrace(), "FAILURE: Failed to check if kernel code address 0x{X} is set: {}\n", .{ vaddr, e });
        if (set) panic(null, "FAILURE: Address before kernel code was set: 0x{X}\n", .{vaddr});
    }
    // Make sure all blocks associated with the kernel code are set
    while (vaddr < v_end) : (vaddr += BLOCK_SIZE) {
        const set = vmm.isSet(vaddr) catch |e| panic(@errorReturnTrace(), "FAILURE: Failed to check if kernel code address 0x{X} is set: {}\n", .{ vaddr, e });
        if (!set) panic(null, "FAILURE: Address for kernel code was not set: 0x{X}\n", .{vaddr});
    }

    // Make sure all blocks after the kernel code are not set
    while (vaddr < vmm.end - BLOCK_SIZE) : (vaddr += BLOCK_SIZE) {
        const set = vmm.isSet(vaddr) catch |e| panic(@errorReturnTrace(), "Failed to check if address after 0x{X} is set: {}", .{ vaddr, e });
        if (set) panic(null, "Address after kernel code was set: 0x{X}", .{vaddr});
    }

    log.logInfo("VMM: Tested allocations\n", .{});
}
