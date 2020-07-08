/// The supported aarch64-capable raspberry pi boards
pub const RaspberryPiBoard = enum {
    RaspberryPi3,
    RaspberryPi4,

    pub fn fromPartNumber(part_num: u12) ?RaspberryPiBoard {
        return switch (part_num) {
            0xD03 => RaspberryPiBoard.RaspberryPi3,
            0xD08 => RaspberryPiBoard.RaspberryPi4,
            else => null,
        };
    }

    pub fn mmioAddress(self: @This()) usize {
        return switch (self) {
            .RaspberryPi3 => 0x3F000000,
            .RaspberryPi4 => 0xFE000000,
        };
    }

    pub fn memoryKB(self: @This()) usize {
        return switch (self) {
            // TODO: Detect the amount of memory on the RPi4
            .RaspberryPi3, .RaspberryPi4 => 1 * 1024 * 1024,
        };
    }
};
