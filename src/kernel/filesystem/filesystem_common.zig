const std = @import("std");

pub const filesystem_bootsector_boot_code = @import("../arch.zig").internals.filesystem_bootsector_boot_code;

///
/// A convenient function for returning the error type for reading from the stream.
///
/// Arguments:
///     IN comptime StreamType: type - The stream to get the error set from.
///
/// Return: type
///     The Error set for reading.
///
pub fn GetReadError(comptime StreamType: type) type {
    return switch (@typeInfo(StreamType)) {
        .Pointer => |p| p.child.ReadError,
        else => StreamType.ReadError,
    };
}

///
/// A convenient function for returning the error type for writing from the stream.
///
/// Arguments:
///     IN comptime StreamType: type - The stream to get the error set from.
///
/// Return: type
///     The Error set for writing.
///
pub fn GetWriteError(comptime StreamType: type) type {
    return switch (@typeInfo(StreamType)) {
        .Pointer => |p| p.child.WriteError,
        else => StreamType.WriteError,
    };
}

///
/// A convenient function for returning the error type for seeking from the stream.
///
/// Arguments:
///     IN comptime StreamType: type - The stream to get the error set from.
///
/// Return: type
///     The Error set for seeking.
///
pub fn GetSeekError(comptime StreamType: type) type {
    return switch (@typeInfo(StreamType)) {
        .Pointer => |p| p.child.SeekError,
        else => StreamType.SeekError,
    };
}

///
/// A convenient function for returning the error type for get seek position from the stream.
///
/// Arguments:
///     IN comptime StreamType: type - The stream to get the error set from.
///
/// Return: type
///     The Error set for get seek position.
///
pub fn GetGetSeekPosError(comptime StreamType: type) type {
    return switch (@typeInfo(StreamType)) {
        .Pointer => |p| p.child.GetSeekPosError,
        else => StreamType.GetSeekPosError,
    };
}

///
/// Clear the stream. This is the same as writeByteNTimes but with a bigger buffer (4096 bytes).
/// This improves performance a lot.
///
/// Arguments:
///     IN stream: anytype - The stream to clear.
///     IN size: usize     - The size to clear from where the position is in the stream.
///
/// Error: @TypeOf(stream).WriteError
///     @TypeOf(stream).WriteError - Error writing to the stream.
///
pub fn clearStream(stream: anytype, size: usize) GetWriteError(@TypeOf(stream))!void {
    comptime const buff_size = 4096;
    comptime const bytes: [buff_size]u8 = [_]u8{0x00} ** buff_size;

    var remaining: usize = size;
    while (remaining > 0) {
        const to_write = std.math.min(remaining, bytes.len);
        try stream.writer().writeAll(bytes[0..to_write]);
        remaining -= to_write;
    }
}
