const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

pub const StatusRegister = enum {
    A,
    B,
    C,
};

pub const RtcRegister = enum {
    SECOND,
    MINUTE,
    HOUR,
    DAY,
    MONTH,
    YEAR,
    CENTURY,
};

pub fn readRtcRegister(reg: RtcRegister) u8 {
    return mock_framework.performAction("readRtcRegister", u8, .{reg});
}

pub fn readStatusRegister(reg: StatusRegister, comptime disable_nmi: bool) u8 {
    return mock_framework.performAction("readStatusRegister", u8, .{ reg, disable_nmi });
}

pub fn writeStatusRegister(reg: StatusRegister, data: u8, comptime disable_nmi: bool) void {
    return mock_framework.performAction("writeStatusRegister", void, .{ reg, data, disable_nmi });
}
