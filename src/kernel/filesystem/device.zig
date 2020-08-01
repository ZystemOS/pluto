const std = @import("std");
const Allocator = std.mem.Allocator;

/// The functions for a hardware device. A device can be a RAM device where the all content is in
/// RAM, or can be a hard disk drive device for a floppy or CD etc.
pub const Device = struct {
    const Self = @This();

    /// The error set for reading or writing to a device.
    pub const Error = error{
        /// If reading at a offer and length will read past the valid regions of the device.
        OutOfBounds,
    } || Allocator.Error;

    ///
    /// Read from a device. This will be device specific were reading from RAM is difference from
    /// reading from a hard drive. This will allocate memory for the read and return a pointer to
    /// it. The caller must free the memory.
    ///
    /// Arguments:
    ///     IN self: *const Self - The device being operated on.
    ///     IN offset: usize     - The offset into the device to read from.
    ///     IN len: usize        - The length of bytes to read.
    ///
    /// Return: []u8
    ///     The pointer to the allocated bytes read from the device.
    ///
    /// Error: Allocator.Error || Error
    ///     error.OutOfMemory - If there wasn't enough memory to read the data into.
    ///     error.OutOfBounds - If the offset and/or length is past the valid region of the device.
    ///
    const Read = fn (self: *const Self, offset: usize, len: usize) Error![]u8;

    ///
    /// Write to a device. This will be device specific were writing to RAM is difference from
    /// writing to a hard drive.
    ///
    /// Arguments:
    ///     IN self: *const Self - The device being operated on.
    ///     IN offset: usize     - The offset into the device to write to.
    ///     IN bytes: []const u8 - The bytes to write to the device.
    ///
    /// Error: Error
    ///     error.OutOfBounds - If the offset and/or length of bytes is past the valid region of
    ///                         the device.
    ///
    const Write = fn (self: *const Self, offset: usize, bytes: []const u8) Error!void;

    /// The read function.
    read: Read,

    /// The write function.
    write: Write,

    /// Points to a usize field within the underlying device so that the read and write functions
    /// can access its low-level implementation using @fieldParentPtr. For example, this could
    /// point to a usize field within a hard drive devices data structure, which stores all the
    /// data and state that is needed in order to interact with a physical disk.
    /// The value of instance is reserved for future use and so should be left as 0
    instance: *usize,
};
