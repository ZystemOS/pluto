const std = @import("std");
const builtin = @import("builtin");
const is_test = builtin.is_test;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const log = std.log.scoped(.x86_rtc);
const build_options = @import("build_options");
const arch = if (is_test) @import("../../../../test/mock/kernel/arch_mock.zig") else @import("arch.zig");
const pic = @import("pic.zig");
const pit = @import("pit.zig");
const irq = @import("irq.zig");
const cmos = if (is_test) @import("../../../../test/mock/kernel/cmos_mock.zig") else @import("cmos.zig");
const panic = @import("../../panic.zig").panic;
const scheduler = @import("../../scheduler.zig");

/// The Century register is unreliable. We need a APIC interface to infer if we have a century
/// register. So this is a current TODO.
const CURRENT_CENTURY: u32 = 2000;

/// TODO: To do with the unreliable century register. Once have APIC, can use this as a sanity check
/// if the the century register gives a wild answer then the other RTC values maybe wild. So then
/// could report that the CMOS chip is faulty or the battery is dyeing.
const CENTURY_REGISTER: bool = false;

/// The error set that can be returned from some RTC functions.
const RtcError = error{
    /// If setting the rate for interrupts is less than 3 or greater than 15.
    RateError,
};

/// A structure to hold all the date and time information in the RTC.
pub const DateTime = struct {
    second: u32,
    minute: u32,
    hour: u32,
    day: u32,
    month: u32,
    year: u32,
    century: u32,
    day_of_week: u32,
};

/// The number of ticks that has passed when RTC was initially set up.
var ticks: u32 = 0;

var schedule: bool = true;

///
/// Checks if the CMOS chip isn't updating the RTC registers. Call this before reading any RTC
/// registers so don't get inconsistent values.
///
/// Return: bool
///     Whether the CMOS chip is busy and a update is in progress.
///
fn isBusy() bool {
    return (cmos.readStatusRegister(cmos.StatusRegister.A, false) & 0x80) != 0;
}

///
/// Calculate the day of the week from the given day, month and year.
///
/// Arguments:
///     IN date_time: DateTime - The DateTime structure that holds the current day, month and year.
///
/// Return: u8
///     A number that represents the day of the week. 1 = Sunday, 2 = Monday, ...
///
fn calcDayOfWeek(date_time: DateTime) u32 {
    const t = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const year = date_time.year - @boolToInt(date_time.month < 3);
    const month = date_time.month;
    const day = date_time.day;

    return (year + (year / 4) - (year / 100) + (year / 400) + t[month - 1] + day) % 7;
}

///
/// Check if the RTC is in binary coded decimal mode. If the RTC ic counting in BCD, then the 3rd
/// bit in the status register B will be set.
///
/// Return: bool
///     When the RTC is counting in BCD.
///
fn isBcd() bool {
    const reg_b = cmos.readStatusRegister(cmos.StatusRegister.B, false);
    return reg_b & 0x04 != 0;
}

///
/// Check if the RTC in 12 hour mode. If the RTC is in 12 hour mode, then the 2nd bit in the status
/// register B is set and the most significant bit on the hour field is set.
///
/// Arguments:
///     IN date_time: DateTime - The DateTime structure containing at least the hour field set.
///
/// Return: bool
///     Whether the RTC is in 12 hour mode.
///
fn is12Hr(date_time: DateTime) bool {
    const reg_b = cmos.readStatusRegister(cmos.StatusRegister.B, false);
    return reg_b & 0x02 != 0 and date_time.hour & 0x80 != 0;
}

///
/// Convert BCD to binary.
///
/// Arguments:
///     IN bcd: u32 - The binary coded decimal value to convert
///
/// Return: u32
///     The converted BCD value.
///
fn bcdToBinary(bcd: u32) u32 {
    return ((bcd & 0xF0) >> 1) + ((bcd & 0xF0) >> 3) + (bcd & 0xf);
}

///
/// Read the real time clock registers and return them in the DateTime structure. This will read
/// the seconds, minutes, hours, days, months, years, century and day of the week.
///
/// Return: DateTime
///     The data from the CMOS RTC registers.
///
fn readRtcRegisters() DateTime {
    // Make sure there isn't a update in progress
    while (isBusy()) {}

    var date_time = DateTime{
        .second = cmos.readRtcRegister(cmos.RtcRegister.SECOND),
        .minute = cmos.readRtcRegister(cmos.RtcRegister.MINUTE),
        .hour = cmos.readRtcRegister(cmos.RtcRegister.HOUR),
        .day = cmos.readRtcRegister(cmos.RtcRegister.DAY),
        .month = cmos.readRtcRegister(cmos.RtcRegister.MONTH),
        .year = cmos.readRtcRegister(cmos.RtcRegister.YEAR),
        .century = if (CENTURY_REGISTER) cmos.readRtcRegister(cmos.RtcRegister.CENTURY) else CURRENT_CENTURY,
        // This will be filled in later
        .day_of_week = 0,
    };

    // The day of the week register is also very unreliable, so is better to calculate it
    date_time.day_of_week = calcDayOfWeek(date_time);

    return date_time;
}

///
/// The interrupt handler for the RTC.
///
/// Arguments:
///     IN ctx: *arch.CpuState - Pointer to the interrupt context containing the contents
///                                      of the register at the time of the interrupt.
///
fn rtcHandler(ctx: *arch.CpuState) usize {
    ticks +%= 1;

    var ret_esp: usize = undefined;

    // Call the scheduler
    if (schedule) {
        ret_esp = scheduler.pickNextTask(ctx, true);
    } else {
        ret_esp = @ptrToInt(ctx);
    }

    // Need to read status register C
    // Might need to disable the NMI bit, set to true
    _ = cmos.readStatusRegister(cmos.StatusRegister.C, false);

    return ret_esp;
}

///
/// Set the rate at which the interrupts will fire. Ranges from 0x3 to 0xF. Where the frequency
/// is determined by: frequency = 32768 >> (rate-1); This will assume the interrupts are disabled.
///
/// Arguments:
///     IN rate: u4 - The rate value to set the frequency to.
///
/// Error: RtcError
///     RtcError.RateError - If the rate is less than 3.
///
fn setRate(rate: u8) RtcError!void {
    if (rate < 3 or rate > 0xF) {
        return RtcError.RateError;
    }

    // Need to disable the NMI for this process
    const status_a = cmos.readStatusRegister(cmos.StatusRegister.A, true);
    cmos.writeStatusRegister(cmos.StatusRegister.A, (status_a & 0xF0) | rate, true);
}

///
/// Enable interrupts for the RTC. This will assume the interrupts have been disabled before hand.
///
fn enableInterrupts() void {
    // Need to disable the NMI for this process
    const status_b = cmos.readStatusRegister(cmos.StatusRegister.B, true);

    // Set the 7th bit to enable interrupt
    cmos.writeStatusRegister(cmos.StatusRegister.B, status_b | 0x40, true);
}

///
/// Read a stable time from the real time clock registers on the CMOS chip and return a BCD and
/// 12 hour converted date and time.
///
/// Return: DateTime
///     The data from the CMOS RTC registers with correct BCD conversions, 12 hour conversions and
///     the century added to the year.
///
pub fn getDateTime() DateTime {
    var date_time1 = readRtcRegisters();
    var date_time2 = readRtcRegisters();

    // Use the method: Read the registers twice and check if they are the same so to avoid
    // inconsistent values due to RTC updates

    var compare = false;

    inline for (@typeInfo(DateTime).Struct.fields) |field| {
        compare = compare or @field(date_time1, field.name) != @field(date_time2, field.name);
    }

    while (compare) {
        date_time1 = readRtcRegisters();
        date_time2 = readRtcRegisters();

        compare = false;
        inline for (@typeInfo(DateTime).Struct.fields) |field| {
            compare = compare or @field(date_time1, field.name) != @field(date_time2, field.name);
        }
    }

    // Convert BCD to binary if necessary
    if (isBcd()) {
        date_time1.second = bcdToBinary(date_time1.second);
        date_time1.minute = bcdToBinary(date_time1.minute);
        // Needs a special calculation because the upper bit is set
        date_time1.hour = ((date_time1.hour & 0x0F) + (((date_time1.hour & 0x70) / 16) * 10)) | (date_time1.hour & 0x80);
        date_time1.day = bcdToBinary(date_time1.day);
        date_time1.month = bcdToBinary(date_time1.month);
        date_time1.year = bcdToBinary(date_time1.year);
        if (CENTURY_REGISTER) {
            date_time1.century = bcdToBinary(date_time1.century);
        }
    }

    // Need to add on the century to the year
    if (CENTURY_REGISTER) {
        date_time1.year += date_time1.century * 100;
    } else {
        date_time1.year += CURRENT_CENTURY;
    }

    // Convert to 24hr time
    if (is12Hr(date_time1)) {
        date_time1.hour = ((date_time1.hour & 0x7F) + 12) % 24;
    }

    return date_time1;
}

///
/// Initialise the RTC.
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    // Register the interrupt handler
    irq.registerIrq(pic.IRQ_REAL_TIME_CLOCK, rtcHandler) catch |err| switch (err) {
        error.IrqExists => {
            panic(@errorReturnTrace(), "IRQ for RTC, IRQ number: {} exists", .{pic.IRQ_REAL_TIME_CLOCK});
        },
        error.InvalidIrq => {
            panic(@errorReturnTrace(), "IRQ for RTC, IRQ number: {} is invalid", .{pic.IRQ_REAL_TIME_CLOCK});
        },
    };

    // Set the interrupt rate to 512Hz
    setRate(7) catch |err| switch (err) {
        error.RateError => {
            panic(@errorReturnTrace(), "Setting rate error", .{});
        },
    };

    // Enable RTC interrupts
    enableInterrupts();

    // Read status register C to clear any interrupts that may have happened during set up
    _ = cmos.readStatusRegister(cmos.StatusRegister.C, false);

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(),
        else => {},
    }
}

test "isBusy not busy" {
    cmos.initTest();
    defer cmos.freeTest();

    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.A, false, @as(u8, 0x60) },
    );

    try expect(!isBusy());
}

test "isBusy busy" {
    cmos.initTest();
    defer cmos.freeTest();

    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.A, false, @as(u8, 0x80) },
    );

    try expect(isBusy());
}

test "calcDayOfWeek" {
    var date_time = DateTime{
        .second = 0,
        .minute = 0,
        .hour = 0,
        .day = 10,
        .month = 1,
        .year = 2020,
        .century = 0,
        .day_of_week = 0,
    };

    var actual = calcDayOfWeek(date_time);
    var expected = @as(u32, 5);

    try expectEqual(expected, actual);

    date_time.day = 20;
    date_time.month = 7;
    date_time.year = 1940;

    actual = calcDayOfWeek(date_time);
    expected = @as(u32, 6);

    try expectEqual(expected, actual);

    date_time.day = 9;
    date_time.month = 11;
    date_time.year = 2043;

    actual = calcDayOfWeek(date_time);
    expected = @as(u32, 1);

    try expectEqual(expected, actual);

    date_time.day = 1;
    date_time.month = 1;
    date_time.year = 2000;

    actual = calcDayOfWeek(date_time);
    expected = @as(u32, 6);

    try expectEqual(expected, actual);
}

test "isBcd not BCD" {
    cmos.initTest();
    defer cmos.freeTest();

    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x00) },
    );

    try expect(!isBcd());
}

test "isBcd BCD" {
    cmos.initTest();
    defer cmos.freeTest();

    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x04) },
    );

    try expect(isBcd());
}

test "is12Hr not 12Hr" {
    const date_time = DateTime{
        .second = 0,
        .minute = 0,
        .hour = 0,
        .day = 0,
        .month = 0,
        .year = 0,
        .century = 0,
        .day_of_week = 0,
    };

    cmos.initTest();
    defer cmos.freeTest();

    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x00) },
    );

    try expect(!is12Hr(date_time));
}

test "is12Hr 12Hr" {
    const date_time = DateTime{
        .second = 0,
        .minute = 0,
        .hour = 0x80,
        .day = 0,
        .month = 0,
        .year = 0,
        .century = 0,
        .day_of_week = 0,
    };

    cmos.initTest();
    defer cmos.freeTest();

    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x02) },
    );

    try expect(is12Hr(date_time));
}

test "bcdToBinary" {
    var expected = @as(u32, 59);
    var actual = bcdToBinary(0x59);

    try expectEqual(expected, actual);

    expected = @as(u32, 48);
    actual = bcdToBinary(0x48);

    try expectEqual(expected, actual);

    expected = @as(u32, 1);
    actual = bcdToBinary(0x01);

    try expectEqual(expected, actual);
}

test "readRtcRegisters" {
    cmos.initTest();
    defer cmos.freeTest();

    // Have 2 busy loops
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.A, false, @as(u8, 0x80), cmos.StatusRegister.A, false, @as(u8, 0x80), cmos.StatusRegister.A, false, @as(u8, 0x00) },
    );

    // All the RTC registers without century as it isn't supported yet
    cmos.addTestParams("readRtcRegister", .{
        cmos.RtcRegister.SECOND, @as(u8, 1),
        cmos.RtcRegister.MINUTE, @as(u8, 2),
        cmos.RtcRegister.HOUR,   @as(u8, 3),
        cmos.RtcRegister.DAY,    @as(u8, 10),
        cmos.RtcRegister.MONTH,  @as(u8, 1),
        cmos.RtcRegister.YEAR,   @as(u8, 20),
    });

    const expected = DateTime{
        .second = 1,
        .minute = 2,
        .hour = 3,
        .day = 10,
        .month = 1,
        .year = 20,
        .century = 2000,
        .day_of_week = 5,
    };
    const actual = readRtcRegisters();

    try expectEqual(expected, actual);
}

test "readRtc unstable read" {
    cmos.initTest();
    defer cmos.freeTest();

    // No busy loop
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.A, false, @as(u8, 0x00), cmos.StatusRegister.A, false, @as(u8, 0x00) },
    );

    // Reading the RTC registers twice, second time is one second ahead
    cmos.addTestParams("readRtcRegister", .{
        cmos.RtcRegister.SECOND, @as(u8, 1),
        cmos.RtcRegister.MINUTE, @as(u8, 2),
        cmos.RtcRegister.HOUR,   @as(u8, 3),
        cmos.RtcRegister.DAY,    @as(u8, 10),
        cmos.RtcRegister.MONTH,  @as(u8, 1),
        cmos.RtcRegister.YEAR,   @as(u8, 20),
        cmos.RtcRegister.SECOND, @as(u8, 2),
        cmos.RtcRegister.MINUTE, @as(u8, 2),
        cmos.RtcRegister.HOUR,   @as(u8, 3),
        cmos.RtcRegister.DAY,    @as(u8, 10),
        cmos.RtcRegister.MONTH,  @as(u8, 1),
        cmos.RtcRegister.YEAR,   @as(u8, 20),
    });

    // Will try again, and now stable
    // No busy loop
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.A, false, @as(u8, 0x00), cmos.StatusRegister.A, false, @as(u8, 0x00) },
    );
    cmos.addTestParams("readRtcRegister", .{
        cmos.RtcRegister.SECOND, @as(u8, 2),
        cmos.RtcRegister.MINUTE, @as(u8, 2),
        cmos.RtcRegister.HOUR,   @as(u8, 3),
        cmos.RtcRegister.DAY,    @as(u8, 10),
        cmos.RtcRegister.MONTH,  @as(u8, 1),
        cmos.RtcRegister.YEAR,   @as(u8, 20),
        cmos.RtcRegister.SECOND, @as(u8, 2),
        cmos.RtcRegister.MINUTE, @as(u8, 2),
        cmos.RtcRegister.HOUR,   @as(u8, 3),
        cmos.RtcRegister.DAY,    @as(u8, 10),
        cmos.RtcRegister.MONTH,  @as(u8, 1),
        cmos.RtcRegister.YEAR,   @as(u8, 20),
    });

    // Not BCD
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x00) },
    );

    // Not 12hr
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x00) },
    );

    const expected = DateTime{
        .second = 2,
        .minute = 2,
        .hour = 3,
        .day = 10,
        .month = 1,
        .year = 2020,
        .century = 2000,
        .day_of_week = 5,
    };
    const actual = getDateTime();

    try expectEqual(expected, actual);
}

test "readRtc is BCD" {
    cmos.initTest();
    defer cmos.freeTest();

    // No busy loop
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.A, false, @as(u8, 0x00), cmos.StatusRegister.A, false, @as(u8, 0x00) },
    );

    // Reading the RTC registers once
    cmos.addTestParams("readRtcRegister", .{
        cmos.RtcRegister.SECOND, @as(u8, 0x30),
        cmos.RtcRegister.MINUTE, @as(u8, 0x59),
        cmos.RtcRegister.HOUR,   @as(u8, 0x11),
        cmos.RtcRegister.DAY,    @as(u8, 0x10),
        cmos.RtcRegister.MONTH,  @as(u8, 0x1),
        cmos.RtcRegister.YEAR,   @as(u8, 0x20),
        cmos.RtcRegister.SECOND, @as(u8, 0x30),
        cmos.RtcRegister.MINUTE, @as(u8, 0x59),
        cmos.RtcRegister.HOUR,   @as(u8, 0x11),
        cmos.RtcRegister.DAY,    @as(u8, 0x10),
        cmos.RtcRegister.MONTH,  @as(u8, 0x1),
        cmos.RtcRegister.YEAR,   @as(u8, 0x20),
    });

    // BCD
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x04) },
    );

    // Not 12hr
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x00) },
    );

    const expected = DateTime{
        .second = 30,
        .minute = 59,
        .hour = 11,
        .day = 10,
        .month = 1,
        .year = 2020,
        .century = 2000,
        .day_of_week = 5,
    };
    const actual = getDateTime();

    try expectEqual(expected, actual);
}

test "readRtc is 12 hours" {
    cmos.initTest();
    defer cmos.freeTest();

    // No busy loop
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.A, false, @as(u8, 0x00), cmos.StatusRegister.A, false, @as(u8, 0x00) },
    );

    // Reading the RTC registers once
    cmos.addTestParams("readRtcRegister", .{
        cmos.RtcRegister.SECOND, @as(u8, 1),
        cmos.RtcRegister.MINUTE, @as(u8, 2),
        cmos.RtcRegister.HOUR,   @as(u8, 0x83),
        cmos.RtcRegister.DAY,    @as(u8, 10),
        cmos.RtcRegister.MONTH,  @as(u8, 1),
        cmos.RtcRegister.YEAR,   @as(u8, 20),
        cmos.RtcRegister.SECOND, @as(u8, 1),
        cmos.RtcRegister.MINUTE, @as(u8, 2),
        cmos.RtcRegister.HOUR,   @as(u8, 0x83),
        cmos.RtcRegister.DAY,    @as(u8, 10),
        cmos.RtcRegister.MONTH,  @as(u8, 1),
        cmos.RtcRegister.YEAR,   @as(u8, 20),
    });

    // Not BCD
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x00) },
    );

    // 12hr
    cmos.addTestParams(
        "readStatusRegister",
        .{ cmos.StatusRegister.B, false, @as(u8, 0x02) },
    );

    const expected = DateTime{
        .second = 1,
        .minute = 2,
        .hour = 15,
        .day = 10,
        .month = 1,
        .year = 2020,
        .century = 2000,
        .day_of_week = 5,
    };
    const actual = getDateTime();

    try expectEqual(expected, actual);
}

test "setRate below 3" {
    try expectError(RtcError.RateError, setRate(0));
    try expectError(RtcError.RateError, setRate(1));
    try expectError(RtcError.RateError, setRate(2));
}

test "setRate" {
    cmos.initTest();
    defer cmos.freeTest();

    cmos.addTestParams("readStatusRegister", .{ cmos.StatusRegister.A, true, @as(u8, 0x10) });
    cmos.addTestParams("writeStatusRegister", .{ cmos.StatusRegister.A, @as(u8, 0x17), true });

    const rate = @as(u8, 7);
    try setRate(rate);
}

test "enableInterrupts" {
    cmos.initTest();
    defer cmos.freeTest();

    cmos.addTestParams("readStatusRegister", .{ cmos.StatusRegister.B, true, @as(u8, 0x20) });
    cmos.addTestParams("writeStatusRegister", .{ cmos.StatusRegister.B, @as(u8, 0x60), true });

    enableInterrupts();
}

///
/// Check that the IRQ is registered correctly
///
fn rt_init() void {
    var irq_exists = false;
    irq.registerIrq(pic.IRQ_REAL_TIME_CLOCK, rtcHandler) catch |err| switch (err) {
        error.IrqExists => {
            // We should get this error
            irq_exists = true;
        },
        error.InvalidIrq => {
            panic(@errorReturnTrace(), "FAILURE: IRQ for RTC, IRQ number: {} is invalid\n", .{pic.IRQ_REAL_TIME_CLOCK});
        },
    };

    if (!irq_exists) {
        panic(@errorReturnTrace(), "FAILURE: IRQ for RTC doesn't exists\n", .{});
    }

    // Check the rate
    const status_a = cmos.readStatusRegister(cmos.StatusRegister.A, false);
    if (status_a & @as(u8, 0x0F) != 7) {
        panic(@errorReturnTrace(), "FAILURE: Rate not set properly, got: {}\n", .{status_a & @as(u8, 0x0F)});
    }

    // Check if interrupts are enabled
    const status_b = cmos.readStatusRegister(cmos.StatusRegister.B, true);
    if (status_b & ~@as(u8, 0x40) == 0) {
        panic(@errorReturnTrace(), "FAILURE: Interrupts not enabled\n", .{});
    }

    log.info("Tested init\n", .{});
}

///
/// Check if the interrupt handler is called after a sleep so check that the RTC interrupts fire.
///
fn rt_interrupts() void {
    const prev_ticks = ticks;

    pit.waitTicks(100);

    if (prev_ticks == ticks) {
        panic(@errorReturnTrace(), "FAILURE: No interrupt happened\n", .{});
    }

    log.info("Tested interrupts\n", .{});
}

///
/// Run all the runtime tests.
///
pub fn runtimeTests() void {
    rt_init();

    // Disable the scheduler temporary
    schedule = false;
    // Interrupts aren't enabled yet, so for the runtime tests, enable it temporary
    arch.enableInterrupts();
    rt_interrupts();
    arch.disableInterrupts();
    // Can enable it back
    schedule = true;
}
