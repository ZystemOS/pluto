const std = @import("std");
const mmio = @import("mmio.zig");

pub const Code = enum(u32) {
    RESPONSE_SUCCESS = 0x80000000,
    RESPONSE_ERROR = 0x80000001,
    REQUEST = 0,
};

/// The mailbox message tags
pub const Tag = enum(usize) {
    NULL = 0,
    ALLOCATE_BUFF = 0x40001,
    RELEASE_BUFF = 0x48001,
    GET_PHYS_DIMENSIONS = 0x40003,
    SET_PHYS_DIMENSIONS = 0x48003,
    GET_VIRT_DIMENSIONS = 0x40004,
    SET_VIRT_DIMENSIONS = 0x48004,
    GET_BITS_PER_PIXEL = 0x40005,
    SET_BITS_PER_PIXEL = 0x48005,
    GET_BYTES_PER_ROW = 0x40008,
};

pub const Message = packed struct {
    channel: u4,
    data_addr: u28,
};

const Status = packed struct {
    reserved: u30,
    empty: u1,
    full: u1,
};

pub const Package = struct {
    message: Message,
    data: []align(16) u32,
};

pub fn send(mmio_addr: usize, data: []const u32, allocator: *std.mem.Allocator) std.mem.Allocator.Error!Package {
    // The full message length is the size of the message array + size byte + code byte + 1 byte for the null tag
    const buff_len = data.len + 2 + 1;
    var buff = try allocator.allocAdvanced(u32, 16, buff_len, .exact);

    // Size including the size field itself
    buff[0] = @truncate(u32, buff_len) * @as(u32, @sizeOf(u32));
    // Request code
    buff[1] = @enumToInt(Code.REQUEST);
    // The null terminator
    buff[buff.len - 1] = @enumToInt(Tag.NULL);

    // Copy in the message bytes
    for (data) |word, i| {
        buff[i + 2] = word;
    }
    const msg = Message{ .channel = 8, .data_addr = @truncate(u28, @ptrToInt(buff.ptr) >> 4) };
    // Wait until the mailbox isn't busy
    while (mmio.read(mmio_addr, mmio.Register.MBOX_STATUS) & @enumToInt(Code.RESPONSE_SUCCESS) != 0) {}
    mmio.write(mmio_addr, mmio.Register.MBOX_WRITE, @bitCast(u32, msg));
    return Package{ .message = msg, .data = buff };
}

pub fn read(mmio_addr: usize) Message {
    while (true) {
        var status: Status = @bitCast(Status, mmio.read(mmio_addr, mmio.Register.MBOX_STATUS));
        if (status.empty == 0) break;
    }
    return @bitCast(Message, mmio.read(mmio_addr, mmio.Register.MBOX_READ));
}
