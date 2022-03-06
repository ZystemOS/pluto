const std = @import("std");
const builtin = @import("builtin");
const is_test = builtin.is_test;
const expectEqual = std.testing.expectEqual;
const build_options = @import("build_options");
const arch = if (is_test) @import("../../../../test/mock/kernel/arch_mock.zig") else @import("arch.zig");

/// The current year to be used for calculating the 4 digit year, as the CMOS return the last two
/// digits of the year.
const CURRENT_CENTURY: u8 = 2000;

/// The port address for the CMOS command register.
const ADDRESS: u16 = 0x70;

/// The port address for the CMOS data register.
const DATA: u16 = 0x71;

/// The register location for returning the seconds, (0 - 59).
const REGISTER_SECOND: u8 = 0x00;

/// The register location for returning the minute, (0 - 59).
const REGISTER_MINUTE: u8 = 0x02;

/// The register location for returning the hours, (0 - 23 or 0 - 12 depending if a 12hr or 24hr
/// clock).
const REGISTER_HOUR: u8 = 0x04;

/// The register location for returning the weekday, (0 - 6). Very unreliable, so will calculate
/// the day of the week instead.
const REGISTER_WEEKDAY: u8 = 0x06;

/// The register location for returning the day, (0 - 31).
const REGISTER_DAY: u8 = 0x07;

/// The register location for returning the month, (0 - 11).
const REGISTER_MONTH: u8 = 0x08;

/// The register location for returning the year, (0 - 99).
const REGISTER_YEAR: u8 = 0x09;

/// The register location for returning the century.
const REGISTER_CENTURY: u8 = 0x32;

/// The register location for return the status A register.
const STATUS_REGISTER_A: u8 = 0x0A;

/// The register location for return the status B register.
const STATUS_REGISTER_B: u8 = 0x0B;

/// The register location for return the status C register.
const STATUS_REGISTER_C: u8 = 0x0C;

/// The non-mockable interrupts are on the 8th bit of port 0x70 which is the register select port
/// for the CMOS. This will need to be disabled when selecting CMOS registers.
const NMI_BIT: u8 = 0x80;

/// The enum for selecting the status register to read from
pub const StatusRegister = enum {
    /// Status register A
    A,

    /// Status register B
    B,

    /// Status register C
    C,

    ///
    /// Get the register index for the status registers
    ///
    /// Arguments:
    ///     IN reg: StatusRegister - The enum that represents one of the 3 status registers.
    ///
    /// Return: u8
    ///     The register index for one of the 3 status registers.
    ///
    pub fn getRegister(reg: StatusRegister) u8 {
        return switch (reg) {
            .A => STATUS_REGISTER_A,
            .B => STATUS_REGISTER_B,
            .C => STATUS_REGISTER_C,
        };
    }
};

/// The enum for selecting the real time clock registers.
pub const RtcRegister = enum {
    /// The seconds register
    SECOND,

    /// The minutes register
    MINUTE,

    /// The hours register
    HOUR,

    /// The days register
    DAY,

    /// The months register
    MONTH,

    /// The year register
    YEAR,

    /// The century register
    CENTURY,

    ///
    /// Get the register index for the RTC registers
    ///
    /// Arguments:
    ///     IN reg: RtcRegister - The enum that represents one of the RTC registers.
    ///
    /// Return: u8
    ///     The register index for one of the RTC registers.
    ///
    pub fn getRegister(reg: RtcRegister) u8 {
        return switch (reg) {
            .SECOND => REGISTER_SECOND,
            .MINUTE => REGISTER_MINUTE,
            .HOUR => REGISTER_HOUR,
            .DAY => REGISTER_DAY,
            .MONTH => REGISTER_MONTH,
            .YEAR => REGISTER_YEAR,
            .CENTURY => REGISTER_CENTURY,
        };
    }
};

///
/// Tell the CMOS chip to select the given register ready for read or writing to. This also
/// disables the NMI when disable_nmi is true.
///
/// Arguments:
///     IN reg: u8                    - The register index to select in the CMOS chip.
///     IN comptime disable_nmi: bool - Whether to disable NMI when selecting a register.
///
inline fn selectRegister(reg: u8, comptime disable_nmi: bool) void {
    if (disable_nmi) {
        arch.out(ADDRESS, reg | NMI_BIT);
    } else {
        arch.out(ADDRESS, reg);
    }
}

///
/// Write to the selected register to the CMOS chip.
///
/// Arguments:
///     IN data: u8 - The data to write to the selected register.
///
inline fn writeRegister(data: u8) void {
    arch.out(DATA, data);
}

///
/// Read the selected register from the CMOS chip.
///
/// Return: u8
///     The value in the selected register.
///
inline fn readRegister() u8 {
    return arch.in(u8, DATA);
}

///
/// Select then read a register from the CMOS chip. This include a I/O wait to ensure the CMOS chip
/// has time to select the register.
///
/// Arguments:
///     IN reg: u8                    - The register index to select in the CMOS chip.
///     IN comptime disable_nmi: bool - Whether to disable NMI when selecting a register.
///
/// Return: u8
///     The value in the selected register.
///
inline fn selectAndReadRegister(reg: u8, comptime disable_nmi: bool) u8 {
    selectRegister(reg, disable_nmi);
    arch.ioWait();
    return readRegister();
}

///
/// Select then write to a register to the CMOS chip. This include a I/O wait to ensure the CMOS chip
/// has time to select the register.
///
/// Arguments:
///     IN reg: u8                    - The register index to select in the CMOS chip.
///     IN data: u8                   - The data to write to the selected register.
///     IN comptime disable_nmi: bool - Whether to disable NMI when selecting a register.
///
inline fn selectAndWriteRegister(reg: u8, data: u8, comptime disable_nmi: bool) void {
    selectRegister(reg, disable_nmi);
    arch.ioWait();
    writeRegister(data);
}

///
/// Read a register that corresponds to a real time clock register.
///
/// Arguments:
///     IN reg: RtcRegister - A RTC register to select in the CMOS chip.
///
/// Return: u8
///     The value in the selected register.
///
pub fn readRtcRegister(reg: RtcRegister) u8 {
    return selectAndReadRegister(reg.getRegister(), false);
}

///
/// Read a status register in the CMOS chip.
///
/// Arguments:
///     IN reg: StatusRegister        - The status register to select.
///     IN comptime disable_nmi: bool - Whether to disable NMI when selecting a register.
///
/// Return: u8
///     The value in the selected register.
///
pub fn readStatusRegister(reg: StatusRegister, comptime disable_nmi: bool) u8 {
    return selectAndReadRegister(reg.getRegister(), disable_nmi);
}

///
/// Write to a status register in the CMOS chip.
///
/// Arguments:
///     IN reg: StatusRegister        - The status register to select.
///     IN data: u8                   - The data to write to the selected register.
///     IN comptime disable_nmi: bool - Whether to disable NMI when selecting a register.
///
pub fn writeStatusRegister(reg: StatusRegister, data: u8, comptime disable_nmi: bool) void {
    selectAndWriteRegister(reg.getRegister(), data, disable_nmi);
}

test "selectRegister" {
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("out", .{ ADDRESS, STATUS_REGISTER_A });

    const reg = STATUS_REGISTER_A;

    selectRegister(reg, false);
}

test "selectRegister no NMI" {
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("out", .{ ADDRESS, STATUS_REGISTER_A | NMI_BIT });

    const reg = STATUS_REGISTER_A;

    selectRegister(reg, true);
}

test "writeRegister" {
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("out", .{ DATA, @as(u8, 0xAA) });

    const data = @as(u8, 0xAA);

    writeRegister(data);
}

test "readRegister" {
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("in", .{ DATA, @as(u8, 0x55) });

    const expected = @as(u8, 0x55);
    const actual = readRegister();

    try expectEqual(expected, actual);
}

test "selectAndReadRegister NMI" {
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("out", .{ ADDRESS, STATUS_REGISTER_C });
    arch.addTestParams("in", .{ DATA, @as(u8, 0x44) });
    arch.addConsumeFunction("ioWait", arch.mock_ioWait);

    const reg = STATUS_REGISTER_C;

    const expected = @as(u8, 0x44);
    const actual = selectAndReadRegister(reg, false);

    try expectEqual(expected, actual);
}

test "selectAndReadRegister no NMI" {
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("out", .{ ADDRESS, STATUS_REGISTER_C | NMI_BIT });
    arch.addTestParams("in", .{ DATA, @as(u8, 0x44) });
    arch.addConsumeFunction("ioWait", arch.mock_ioWait);

    const reg = STATUS_REGISTER_C;

    const expected = @as(u8, 0x44);
    const actual = selectAndReadRegister(reg, true);

    try expectEqual(expected, actual);
}

test "selectAndWriteRegister NMI" {
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("out", .{ ADDRESS, STATUS_REGISTER_C, DATA, @as(u8, 0x88) });
    arch.addConsumeFunction("ioWait", arch.mock_ioWait);

    const reg = STATUS_REGISTER_C;
    const data = @as(u8, 0x88);

    selectAndWriteRegister(reg, data, false);
}

test "selectAndWriteRegister no NMI" {
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("out", .{ ADDRESS, STATUS_REGISTER_C | NMI_BIT, DATA, @as(u8, 0x88) });
    arch.addConsumeFunction("ioWait", arch.mock_ioWait);

    const reg = STATUS_REGISTER_C;
    const data = @as(u8, 0x88);

    selectAndWriteRegister(reg, data, true);
}

test "readRtcRegister" {
    arch.initTest();
    defer arch.freeTest();

    arch.addRepeatFunction("ioWait", arch.mock_ioWait);

    const rtc_regs = [_]RtcRegister{ RtcRegister.SECOND, RtcRegister.MINUTE, RtcRegister.HOUR, RtcRegister.DAY, RtcRegister.MONTH, RtcRegister.YEAR, RtcRegister.CENTURY };

    for (rtc_regs) |reg| {
        const r = switch (reg) {
            .SECOND => REGISTER_SECOND,
            .MINUTE => REGISTER_MINUTE,
            .HOUR => REGISTER_HOUR,
            .DAY => REGISTER_DAY,
            .MONTH => REGISTER_MONTH,
            .YEAR => REGISTER_YEAR,
            .CENTURY => REGISTER_CENTURY,
        };

        arch.addTestParams("out", .{ ADDRESS, r });
        arch.addTestParams("in", .{ DATA, @as(u8, 0x44) });

        const expected = @as(u8, 0x44);
        const actual = readRtcRegister(reg);

        try expectEqual(expected, actual);
    }
}

test "readStatusRegister NMI" {
    arch.initTest();
    defer arch.freeTest();

    arch.addRepeatFunction("ioWait", arch.mock_ioWait);

    const status_regs = [_]StatusRegister{ StatusRegister.A, StatusRegister.B, StatusRegister.C };

    for (status_regs) |reg| {
        const r = switch (reg) {
            .A => STATUS_REGISTER_A,
            .B => STATUS_REGISTER_B,
            .C => STATUS_REGISTER_C,
        };

        arch.addTestParams("out", .{ ADDRESS, r });
        arch.addTestParams("in", .{ DATA, @as(u8, 0x78) });

        const expected = @as(u8, 0x78);
        const actual = readStatusRegister(reg, false);

        try expectEqual(expected, actual);
    }
}

test "readStatusRegister no NMI" {
    arch.initTest();
    defer arch.freeTest();

    arch.addRepeatFunction("ioWait", arch.mock_ioWait);

    const status_regs = [_]StatusRegister{ StatusRegister.A, StatusRegister.B, StatusRegister.C };

    for (status_regs) |reg| {
        const r = switch (reg) {
            .A => STATUS_REGISTER_A,
            .B => STATUS_REGISTER_B,
            .C => STATUS_REGISTER_C,
        };

        arch.addTestParams("out", .{ ADDRESS, r | NMI_BIT });
        arch.addTestParams("in", .{ DATA, @as(u8, 0x78) });

        const expected = @as(u8, 0x78);
        const actual = readStatusRegister(reg, true);

        try expectEqual(expected, actual);
    }
}

test "writeStatusRegister NMI" {
    arch.initTest();
    defer arch.freeTest();

    arch.addRepeatFunction("ioWait", arch.mock_ioWait);

    const status_regs = [_]StatusRegister{ StatusRegister.A, StatusRegister.B, StatusRegister.C };

    for (status_regs) |reg| {
        const r = switch (reg) {
            .A => STATUS_REGISTER_A,
            .B => STATUS_REGISTER_B,
            .C => STATUS_REGISTER_C,
        };

        arch.addTestParams("out", .{ ADDRESS, r, DATA, @as(u8, 0x43) });

        const data = @as(u8, 0x43);
        writeStatusRegister(reg, data, false);
    }
}

test "writeStatusRegister no NMI" {
    arch.initTest();
    defer arch.freeTest();

    arch.addRepeatFunction("ioWait", arch.mock_ioWait);

    const status_regs = [_]StatusRegister{ StatusRegister.A, StatusRegister.B, StatusRegister.C };

    for (status_regs) |reg| {
        const r = switch (reg) {
            .A => STATUS_REGISTER_A,
            .B => STATUS_REGISTER_B,
            .C => STATUS_REGISTER_C,
        };

        arch.addTestParams("out", .{ ADDRESS, r | NMI_BIT, DATA, @as(u8, 0x43) });

        const data = @as(u8, 0x43);
        writeStatusRegister(reg, data, true);
    }
}
