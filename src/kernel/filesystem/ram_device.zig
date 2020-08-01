const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;
const Device = @import("device.zig").Device;
const Allocator = std.mem.Allocator;

/// A simple RAM device. This can be use for easy testing of file systems. This can also be use for
/// easy creation of in memory file systems.
pub const RamDevice = struct {
    const Self = @This();

    /// The underlying device interface.
    device: *Device,

    /// An allocator to allocate memory when needed.
    allocator: *Allocator,

    /// The memory that the RAM device will control.
    memory: []u8,

    /// See Device.instance.
    instance: usize,

    /// See Device.read
    fn read(device: *const Device, offset: usize, len: usize) Device.Error![]u8 {
        var self = @fieldParentPtr(RamDevice, "instance", device.instance);
        if (self.memory.len - len < offset) {
            return Device.Error.OutOfBounds;
        }
        var buff = try self.allocator.alloc(u8, len);
        std.mem.copy(u8, buff[0..], self.memory[offset .. offset + len]);
        return buff;
    }

    /// See Device.write
    fn write(device: *const Device, offset: usize, bytes: []const u8) Device.Error!void {
        var self = @fieldParentPtr(RamDevice, "instance", device.instance);
        if (self.memory.len - bytes.len < offset) {
            return Device.Error.OutOfBounds;
        }
        std.mem.copy(u8, self.memory[offset..], bytes[0..]);
    }

    ///
    /// De-initialise a RAM device. This will free the underlying device, the memory this device
    /// controls and this device itself.
    ///
    /// Argument:
    ///     IN self: *Self - Self.
    ///
    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self.device);
        self.allocator.free(self.memory);
        self.allocator.destroy(self);
    }

    ///
    /// Initialise a new RAM device with the memory provided duplicated. After this is called, the
    /// memory provided can be freed.
    ///
    /// Arguments:
    ///     IN memory: []u8          - The pointer to the bytes that the RAM device will manage.
    ///     IN allocator: *Allocator - The allocator when needing to allocate memory.
    ///
    /// Return: *RamDevice
    ///     A new RAM device.
    ///
    /// Error: Allocator.Error
    ///     error.OutOfMemory - If there isn't enough memory when initialising the RAM device.
    ///                         Any memory allocated will be freed on return.
    ///
    pub fn init(memory: []u8, allocator: *Allocator) Allocator.Error!*RamDevice {
        const ram_device = try allocator.create(RamDevice);
        errdefer allocator.destroy(ram_device);
        const device = try allocator.create(Device);
        errdefer allocator.destroy(device);

        ram_device.* = .{
            .device = device,
            .allocator = allocator,
            // QUESTION: Should we dupe the memory? We could just have the memory with the same life time as the pointer passed (caller)
            //           Then just ass a comment in the doc comment about the life time.
            //           This would improve speed and memory usage, but the device should control the memory.
            //           Could add 2 init function, one with a size to allocate and one with a memory pointer (this one).
            .memory = try allocator.dupe(u8, memory),
            .instance = 0x4A3,
        };

        device.* = .{
            .read = read,
            .write = write,
            .instance = &ram_device.instance,
        };

        return ram_device;
    }

    // This is temporary so not to dupe the memory.
    pub fn init2(memory: []u8, allocator: *Allocator) Allocator.Error!*RamDevice {
        const ram_device = try allocator.create(RamDevice);
        errdefer allocator.destroy(ram_device);
        const device = try allocator.create(Device);

        ram_device.* = .{
            .device = device,
            .allocator = allocator,
            // QUESTION: Should we dupe the memory? We could just have the memory with the same life time as the pointer passed (caller)
            //           Then just ass a comment in the doc comment about the life time.
            //           This would improve speed and memory usage, but the device should control the memory.
            //           Could add 2 init function, one with a size to allocate and one with a memory pointer (this one).
            .memory = memory,
            .instance = 0x4A3,
        };

        device.* = .{
            .read = read,
            .write = write,
            .instance = &ram_device.instance,
        };

        return ram_device;
    }

    test "init frees memory on error" {
        var buffer: [1024]u8 = undefined;
        for ([_]usize{ 0, 1, 2 }) |i| {
            {
                var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);
                expectError(error.OutOfMemory, RamDevice.init(buffer[0..], &fa.allocator));
            }

            // Ensure we have freed any memory allocated
            try std.testing.allocator_instance.validate();
        }
    }

    test "init" {
        var buffer: [1024]u8 = [_]u8{0xAA} ** 1024;
        var ram_device = try RamDevice.init(buffer[0..], std.testing.allocator);
        defer ram_device.deinit();
        // Every thing should be 0xAA
        for (ram_device.memory) |m| {
            expectEqual(m, 0xAA);
        }
    }

    test "read OutOfMemory" {
        var buffer: [1024]u8 = [_]u8{0xAA} ** 1024;
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, 3);
        var ram_device = try RamDevice.init(buffer[0..], &fa.allocator);
        const device = ram_device.device;
        defer ram_device.deinit();

        expectError(error.OutOfMemory, device.read(device, 0, 1));
    }

    test "read OutOfBounds" {
        var buffer: [1024]u8 = [_]u8{0xAA} ** 1024;
        var ram_device = try RamDevice.init(buffer[0..], std.testing.allocator);
        const device = ram_device.device;
        defer ram_device.deinit();

        expectError(error.OutOfBounds, device.read(device, 1020, 5));
        expectError(error.OutOfBounds, device.read(device, 1023, 2));
        expectError(error.OutOfBounds, device.read(device, 1024, 1));
        expectError(error.OutOfBounds, device.read(device, 1025, 1));
        expectError(error.OutOfBounds, device.read(device, 2000, 0));
    }

    test "read" {
        var buffer: [1024]u8 = [_]u8{0xAA} ** 1024;
        var ram_device = try RamDevice.init(buffer[0..], std.testing.allocator);
        const device = ram_device.device;
        defer ram_device.deinit();

        const read1 = try device.read(device, 1023, 1);
        defer std.testing.allocator.free(read1);
        const read2 = try device.read(device, 1020, 4);
        defer std.testing.allocator.free(read2);
        const read3 = try device.read(device, 1024, 0);
        defer std.testing.allocator.free(read3);

        expectEqualSlices(u8, read1, &[_]u8{0xAA});
        expectEqualSlices(u8, read2, &[_]u8{ 0xAA, 0xAA, 0xAA, 0xAA });
        expectEqualSlices(u8, read3, &[_]u8{});
    }

    test "write OutOfBounds" {
        var buffer: [1024]u8 = [_]u8{0xAA} ** 1024;
        var ram_device = try RamDevice.init(buffer[0..], std.testing.allocator);
        const device = ram_device.device;
        defer ram_device.deinit();

        const write0 = &[_]u8{};
        const write1 = &[_]u8{0xBB};
        const write2 = &[_]u8{ 0xBB, 0xBB };
        const write5 = &[_]u8{ 0xBB, 0xBB, 0xBB, 0xBB, 0xBB };

        expectError(error.OutOfBounds, device.write(device, 1020, write5));
        expectError(error.OutOfBounds, device.write(device, 1023, write2));
        expectError(error.OutOfBounds, device.write(device, 1024, write1));
        expectError(error.OutOfBounds, device.write(device, 1025, write1));
        expectError(error.OutOfBounds, device.write(device, 2000, write0));
    }

    test "write" {
        var buffer: [1024]u8 = [_]u8{0xAA} ** 1024;
        var ram_device = try RamDevice.init(buffer[0..], std.testing.allocator);
        const device = ram_device.device;
        defer ram_device.deinit();

        const write5 = &[_]u8{ 0xBB, 0xBB, 0xBB, 0xBB, 0xBB };

        try device.write(device, 1000, write5);
        for (ram_device.memory) |m, i| {
            if (i >= 1000 and i < 1005) {
                expectEqual(m, 0xBB);
            } else {
                expectEqual(m, 0xAA);
            }
        }
        // Original mem is unchanged
        for (buffer) |m, i| {
            expectEqual(m, 0xAA);
        }
    }
};
