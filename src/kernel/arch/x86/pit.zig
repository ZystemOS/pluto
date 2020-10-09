const std = @import("std");
const maxInt = std.math.maxInt;
const builtin = @import("builtin");
const is_test = builtin.is_test;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const log = std.log.scoped(.x86_pit);
const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");
const panic = if (is_test) @import(mock_path ++ "panic_mock.zig").panic else @import("../../panic.zig").panic;
const irq = @import("irq.zig");
const pic = @import("pic.zig");

/// The enum for selecting the counter
const CounterSelect = enum {
    /// Counter 0.
    Counter0,

    /// Counter 1.
    Counter1,

    /// Counter 2.
    Counter2,

    ///
    /// Get the register port for the selected counter.
    ///
    /// Arguments:
    ///     IN counter: CounterSelect - The counter to get the register port.
    ///
    /// Return: u16
    ///     The register port for the selected counter.
    ///
    pub fn getRegister(counter: CounterSelect) u16 {
        return switch (counter) {
            .Counter0 => COUNTER_0_REGISTER,
            .Counter1 => COUNTER_1_REGISTER,
            .Counter2 => COUNTER_2_REGISTER,
        };
    }

    ///
    /// Get the operational control work for the selected counter.
    ///
    /// Arguments:
    ///     IN counter: CounterSelect - The counter to get the operational control work.
    ///
    /// Return: u16
    ///     The operational control work for the selected counter.
    ///
    pub fn getCounterOCW(counter: CounterSelect) u8 {
        return switch (counter) {
            .Counter0 => OCW_SELECT_COUNTER_0,
            .Counter1 => OCW_SELECT_COUNTER_1,
            .Counter2 => OCW_SELECT_COUNTER_2,
        };
    }
};

/// The error set that can be returned from PIT functions
const PitError = error{
    /// The frequency to be used for a counter is invalid. This would be if the frequency is less
    /// than 19 or greater than MAX_FREQUENCY.
    InvalidFrequency,
};

/// The port address for the PIT data register for counter 0. This is going to be used as the
/// system clock.
const COUNTER_0_REGISTER: u16 = 0x40;

/// The port address for the PIT data register for counter 1. This was used for refreshing the DRAM
/// chips. But now is unused and unknown use, so won't use.
const COUNTER_1_REGISTER: u16 = 0x41;

/// The port address for the PIT data register for counter 2. Connected to the PC speakers, we'll
/// use this for the speakers.
const COUNTER_2_REGISTER: u16 = 0x42;

/// The port address for the PIT control word register. Used to tell the PIT controller what is
/// about to happen. Tell what data is going where, lower or upper part of it's registers.
const COMMAND_REGISTER: u16 = 0x43;

// The operational command word for the different modes.
//
// Bit 0: (BCP) Binary Counter.
//     0: Binary.
//     1: Binary Coded Decimal (BCD).
// Bit 1-3: (M0, M1, M2) Operating Mode. See above sections for a description of each.
//     000: Mode 0: Interrupt or Terminal Count.
//     001: Mode 1: Programmable one-shot.
//     010: Mode 2: Rate Generator.
//     011: Mode 3: Square Wave Generator.
//     100: Mode 4: Software Triggered Strobe.
//     101: Mode 5: Hardware Triggered Strobe.
//     110: Undefined; Don't use.
//     111: Undefined; Don't use.
// Bits 4-5: (RL0, RL1) Read/Load Mode. We are going to read or send data to a counter register.
//     00: Counter value is latched into an internal control register at the time of the I/O write operation.
//     01: Read or Load Least Significant Byte (LSB) only.
//     10: Read or Load Most Significant Byte (MSB) only.
//     11: Read or Load LSB first then MSB.
// Bits 6-7: (SC0-SC1) Select Counter. See above sections for a description of each.
//     00: Counter 0.
//     01: Counter 1.
//     10: Counter 2.
//     11: Illegal value.

/// Have the counter count in binary (internally?).
const OCW_BINARY_COUNT_BINARY: u8 = 0x00;

/// Have the counter count in BCD (internally?).
const OCW_BINARY_COUNT_BCD: u8 = 0x01;

/// The PIT counter will be programmed with an initial COUNT value that counts down at a rate of
/// the input clock frequency. When the COUNT reaches 0, and after the control word is written,
/// then its OUT pit is set high (1). Count down starts then the COUNT is set. The OUT pin remains
/// high until the counter is reloaded with a new COUNT value or a new control work is written.
const OCW_MODE_TERMINAL_COUNT: u8 = 0x00;

/// The counter is programmed to output a pulse every curtain number of clock pulses. The OUT pin
/// remains high as soon as a control word is written. When COUNT is written, the counter waits
/// until the rising edge of the GATE pin to start. One clock pulse after the GATE pin, the OUT
/// pin will remain low until COUNT reaches 0.
const OCW_MODE_ONE_SHOT: u8 = 0x02;

/// The counter is initiated with a COUNT value. Counting starts next clock pulse. OUT pin remains
/// high until COUNT reaches 1, then is set low for one clock pulse. Then COUNT is reset back to
/// initial value and OUT pin is set high again.
const OCW_MODE_RATE_GENERATOR: u8 = 0x04;

/// Similar to PIT_OCW_MODE_RATE_GENERATOR, but OUT pin will be high for half the time and low for
/// half the time. Good for the speaker when setting a tone.
const OCW_MODE_SQUARE_WAVE_GENERATOR: u8 = 0x06;

/// The counter is initiated with a COUNT value. Counting starts on next clock pulse. OUT pin remains
/// high until count is 0. Then OUT pin is low for one clock pulse. Then resets to high again.
const OCW_MODE_SOFTWARE_TRIGGER: u8 = 0x08;

/// The counter is initiated with a COUNT value. OUT pin remains high until the rising edge of the
/// GATE pin. Then the counting begins. When COUNT reaches 0, OUT pin goes low for one clock pulse.
/// Then COUNT is reset and OUT pin goes high. This cycles for each rising edge of the GATE pin.
const OCW_MODE_HARDWARE_TRIGGER: u8 = 0x0A;

/// The counter value is latched into an internal control register at the time of the I/O write
/// operations.
const OCW_READ_LOAD_LATCH: u8 = 0x00;

/// Read or load the most significant bit only.
const OCW_READ_LOAD_LSB_ONLY: u8 = 0x10;

/// Read or load the least significant bit only.
const OCW_READ_LOAD_MSB_ONLY: u8 = 0x20;

/// Read or load the least significant bit first then the most significant bit.
const OCW_READ_LOAD_DATA: u8 = 0x30;

/// The OCW bits for selecting counter 0. Used for the system clock.
const OCW_SELECT_COUNTER_0: u8 = 0x00;

/// The OCW bits for selecting counter 1. Was for the memory refreshing.
const OCW_SELECT_COUNTER_1: u8 = 0x40;

/// The OCW bits for selecting counter 2. Channel for the speaker.
const OCW_SELECT_COUNTER_2: u8 = 0x80;

/// The divisor constant
const MAX_FREQUENCY: u32 = 1193182;

/// The number of ticks that has passed when counter 0 was initially set up.
var ticks: u32 = 0;

/// The number of tick that has passed when counter 1 was initially set up.
var ram_ticks: u32 = 0;

/// The number of tick that has passed when counter 2 was initially set up.
var speaker_ticks: u32 = 0;

/// The current frequency of counter 0
var current_freq_0: u32 = undefined;

/// The current frequency of counter 1
var current_freq_1: u32 = undefined;

/// The current frequency of counter 2
var current_freq_2: u32 = undefined;

/// The number of nanoseconds between interrupts.
var time_ns: u32 = undefined;

/// The number of nanoseconds to be added the to time_ns for time between interrupts.
var time_under_1_ns: u32 = undefined;

///
/// Send a command to the PIT command register.
///
/// Arguments:
///     IN cmd: u8 - The command to send to the PIT.
///
inline fn sendCommand(cmd: u8) void {
    arch.out(COMMAND_REGISTER, cmd);
}

///
/// Read the current mode of the selected counter.
///
/// Arguments:
///     IN counter: CounterSelect - The counter to read the mode the counter is operating in.
///
/// Return: u8
///     The mode the counter is operating in. Use the masks above to get each part.
///
inline fn readBackCommand(counter: CounterSelect) u8 {
    sendCommand(0xC2);
    return 0x3F & arch.in(u8, counter.getRegister());
}

///
/// Send data to a given counter. Will be only one of the 3 counters as is an internal function.
///
/// Arguments:
///     IN counter: CounterSelect - The counter port to send the data to.
///     IN data: u8               - The data to send.
///
inline fn sendDataToCounter(counter: CounterSelect, data: u8) void {
    arch.out(counter.getRegister(), data);
}

///
/// The interrupt handler for the PIT. This will increment a counter for now.
///
/// Arguments:
///     IN ctx: *arch.CpuState - Pointer to the interrupt context containing the contents
///                                      of the register at the time of the interrupt.
///
fn pitHandler(ctx: *arch.CpuState) usize {
    ticks +%= 1;
    return @ptrToInt(ctx);
}

///
/// Set up a counter with a tick rate and mode of operation.
///
/// Arguments:
///     IN counter: CounterSelect - Which counter is to be set up.
///     IN freq: u32              - The frequency that the counter operates at. Any frequency that
///                                 is between 0..18 (inclusive) or above MAX_FREQUENCY will return
///                                 an error.
///     IN mode: u8               - The mode of operation that the counter will operate in. See
///                                 the modes definition above to chose which mode the counter is
///                                 to run at.
///
/// Error: PitError:
///     PitError.InvalidFrequency - If the given frequency is out of bounds. Less than 19 or
///                                 greater than MAX_FREQUENCY.
///
fn setupCounter(counter: CounterSelect, freq: u32, mode: u8) PitError!void {
    if (freq < 19 or freq > MAX_FREQUENCY) {
        return PitError.InvalidFrequency;
    }

    // 65536, the slowest possible frequency. Roughly 19Hz
    var reload_value: u32 = 0x10000;

    // The lowest possible frequency is 18Hz.
    // MAX_FREQUENCY / 18 > u16 N
    // MAX_FREQUENCY / 19 < u16 Y
    if (freq > 18) {
        if (freq < MAX_FREQUENCY) {
            // Rounded integer division
            reload_value = (MAX_FREQUENCY + (freq / 2)) / freq;
        } else {
            // The fastest possible frequency if frequency is too high
            reload_value = 1;
        }
    }

    // Update the frequency with the actual one that the PIT will be using
    // Rounded integer division
    const frequency = (MAX_FREQUENCY + (reload_value / 2)) / reload_value;

    // Calculate the amount of nanoseconds between interrupts
    time_ns = 1000000000 / frequency;

    // Calculate the number of picoseconds, the left over from nanoseconds
    time_under_1_ns = ((1000000000 % frequency) * 1000 + (frequency / 2)) / frequency;

    // Set the frequency for the counter being set up
    switch (counter) {
        .Counter0 => current_freq_0 = frequency,
        .Counter1 => current_freq_1 = frequency,
        .Counter2 => current_freq_2 = frequency,
    }

    // Get the u16 version as this is what will be loaded into the PIT
    // If truncating 0x10000, this will equal 0, which is the slowest.
    const reload_val_16 = @truncate(u16, reload_value);

    // Send the set up command to the PIT
    sendCommand(mode | OCW_READ_LOAD_DATA | counter.getCounterOCW());
    sendDataToCounter(counter, @truncate(u8, reload_val_16));
    sendDataToCounter(counter, @truncate(u8, reload_val_16 >> 8));

    // Reset the counter ticks
    switch (counter) {
        .Counter0 => ticks = 0,
        .Counter1 => ram_ticks = 0,
        .Counter2 => speaker_ticks = 0,
    }
}

///
/// A simple wait that used the PIT to wait a number of ticks.
///
/// Arguments:
///     IN ticks_to_wait: u32 - The number of ticks to wait.
///
pub fn waitTicks(ticks_to_wait: u32) void {
    if (ticks > maxInt(u32) - ticks_to_wait) {
        // Integer overflow

        // Calculate the 2 conditions
        const wait_ticks1 = maxInt(u32) - ticks;
        const wait_ticks2 = ticks_to_wait - wait_ticks1;

        while (ticks > wait_ticks1) {
            arch.halt();
        }

        while (ticks < wait_ticks2) {
            arch.halt();
        }
    } else {
        const wait_ticks = ticks + ticks_to_wait;
        while (ticks < wait_ticks) {
            arch.halt();
        }
    }
}

///
/// Get the number of ticks that have passed when the PIT was initiated.
///
/// Return: u32
///     Number of ticks passed.
///
pub fn getTicks() u32 {
    return ticks;
}

///
/// Get the frequency the PIT is ticking at.
///
/// Return: u32
///     The frequency the PIT is running at
///
pub fn getFrequency() u32 {
    return current_freq_0;
}

///
/// Initialise the PIT with a handler to IRQ 0.
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    // Set up counter 0 at 10000hz in a square wave mode counting in binary
    const freq: u32 = 10000;
    setupCounter(CounterSelect.Counter0, freq, OCW_MODE_SQUARE_WAVE_GENERATOR | OCW_BINARY_COUNT_BINARY) catch |e| {
        panic(@errorReturnTrace(), "Invalid frequency: {}\n", .{freq});
    };

    log.debug("Set frequency at: {}Hz, real frequency: {}Hz\n", .{ freq, getFrequency() });

    // Installs 'pitHandler' to IRQ0 (pic.IRQ_PIT)
    irq.registerIrq(pic.IRQ_PIT, pitHandler) catch |err| switch (err) {
        error.IrqExists => {
            panic(@errorReturnTrace(), "IRQ for PIT, IRQ number: {} exists", .{pic.IRQ_PIT});
        },
        error.InvalidIrq => {
            panic(@errorReturnTrace(), "IRQ for PIT, IRQ number: {} is invalid", .{pic.IRQ_PIT});
        },
    };

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(),
        else => {},
    }
}

test "sendCommand" {
    arch.initTest();
    defer arch.freeTest();

    const cmd: u8 = 10;

    arch.addTestParams("out", .{ COMMAND_REGISTER, cmd });

    sendCommand(cmd);
}

test "readBackCommand" {
    arch.initTest();
    defer arch.freeTest();

    const cmd: u8 = 0xC2;

    arch.addTestParams("out", .{ COMMAND_REGISTER, cmd });
    arch.addTestParams("in", .{ COUNTER_0_REGISTER, @as(u8, 0x20) });

    const actual = readBackCommand(CounterSelect.Counter0);

    expectEqual(@as(u8, 0x20), actual);
}

test "sendDataToCounter" {
    arch.initTest();
    defer arch.freeTest();

    const data: u8 = 10;

    arch.addTestParams("out", .{ COUNTER_0_REGISTER, data });

    sendDataToCounter(CounterSelect.Counter0, data);
}

test "setupCounter lowest frequency" {
    arch.initTest();
    defer arch.freeTest();

    const counter = CounterSelect.Counter0;
    const port = counter.getRegister();

    var freq: u32 = 0;

    // Reload value will be 0 (0x10000), the slowest speed for frequency less than 19
    const expected_reload_value: u16 = 0;

    // Slowest frequency the PIT can run at
    const expected_freq: u32 = 19;

    const mode = OCW_MODE_SQUARE_WAVE_GENERATOR | OCW_BINARY_COUNT_BINARY;
    const command = mode | OCW_READ_LOAD_DATA | counter.getCounterOCW();

    while (freq <= 18) : (freq += 1) {
        // arch.addTestParams("out", COMMAND_REGISTER, command, port, @truncate(u8, expected_reload_value), port, @truncate(u8, expected_reload_value >> 8));
        expectError(PitError.InvalidFrequency, setupCounter(counter, freq, mode));

        // expectEqual(u32(0), ticks);
        // expectEqual(expected_freq, current_freq_0);
        // expectEqual(expected_freq, getFrequency());

        // // These are the hard coded expected values. Calculated externally to check the internal calculation
        // expectEqual(u32(52631578), time_ns);
        // expectEqual(u32(947), time_under_1_ns);
    }

    // Reset globals
    time_ns = 0;
    current_freq_0 = 0;
    ticks = 0;
}

test "setupCounter highest frequency" {
    arch.initTest();
    defer arch.freeTest();

    const counter = CounterSelect.Counter0;
    const port = counter.getRegister();

    // Set the frequency above the maximum
    const freq = MAX_FREQUENCY + 10;

    // Reload value will be 1, the fastest speed for frequency greater than MAX_FREQUENCY
    const expected_reload_value = 1;

    // Slowest frequency the PIT can run at
    const expected_freq = MAX_FREQUENCY;

    const mode = OCW_MODE_SQUARE_WAVE_GENERATOR | OCW_BINARY_COUNT_BINARY;
    const command = mode | OCW_READ_LOAD_DATA | counter.getCounterOCW();

    // arch.addTestParams("out", COMMAND_REGISTER, command, port, @truncate(u8, expected_reload_value), port, @truncate(u8, expected_reload_value >> 8));

    expectError(PitError.InvalidFrequency, setupCounter(counter, freq, mode));

    // expectEqual(u32(0), ticks);
    // expectEqual(expected_freq, current_freq_0);
    // expectEqual(expected_freq, getFrequency());

    // // These are the hard coded expected values. Calculated externally to check the internal calculation
    // expectEqual(u32(838), time_ns);
    // expectEqual(u32(95), time_under_1_ns);

    // Reset globals
    time_ns = 0;
    current_freq_0 = 0;
    ticks = 0;
}

test "setupCounter normal frequency" {
    arch.initTest();
    defer arch.freeTest();

    const counter = CounterSelect.Counter0;
    const port = counter.getRegister();

    // Set the frequency to a normal frequency
    const freq = 10000;
    const expected_reload_value = 119;
    const expected_freq: u32 = 10027;

    const mode = OCW_MODE_SQUARE_WAVE_GENERATOR | OCW_BINARY_COUNT_BINARY;
    const command = mode | OCW_READ_LOAD_DATA | counter.getCounterOCW();

    arch.addTestParams("out", .{ COMMAND_REGISTER, command, port, @truncate(u8, expected_reload_value), port, @truncate(u8, expected_reload_value >> 8) });

    setupCounter(counter, freq, mode) catch unreachable;

    expectEqual(@as(u32, 0), ticks);
    expectEqual(expected_freq, current_freq_0);
    expectEqual(expected_freq, getFrequency());

    // These are the hard coded expected values. Calculated externally to check the internal calculation
    expectEqual(@as(u32, 99730), time_ns);
    expectEqual(@as(u32, 727), time_under_1_ns);

    // Reset globals
    time_ns = 0;
    current_freq_0 = 0;
    ticks = 0;
}

///
/// Test that waiting a number of ticks and then getting the number of ticks match.
///
fn rt_waitTicks() void {
    const waiting = 1000;
    const epsilon = 2 * getFrequency() / 10000;

    const previous_count = getTicks();

    waitTicks(waiting);

    const difference = getTicks() - waiting;

    if (previous_count + epsilon < difference or previous_count > difference + epsilon) {
        panic(@errorReturnTrace(), "FAILURE: Waiting failed. difference: {}, previous_count: {}. Epsilon: {}\n", .{ difference, previous_count, epsilon });
    }

    log.info("Tested wait ticks\n", .{});
}

///
/// Test that waiting a number of ticks and then getting the number of ticks match. This version
/// checks for the ticks wrap around.
///
fn rt_waitTicks2() void {
    // Set the ticks to 16 less than the max
    const waiting = 1000;
    const epsilon = 2 * getFrequency() / 10000;

    ticks = 0xFFFFFFF0;
    const previous_count = getTicks() - 0xFFFFFFF0;

    waitTicks(waiting);

    // maxInt(u32) - u32(0xFFFFFFF0) = 15
    const difference = getTicks() + 15 - waiting;

    if (previous_count + epsilon < difference or previous_count > difference + epsilon) {
        panic(@errorReturnTrace(), "FAILURE: Waiting failed. difference: {}, previous_count: {}. Epsilon: {}\n", .{ difference, previous_count, epsilon });
    }

    // Reset ticks
    ticks = 0;

    log.info("Tested wait ticks 2\n", .{});
}

///
/// Check that when the PIT is initialised, counter 0 is set up properly.
///
fn rt_initCounter_0() void {
    const expected_ns: u32 = 99730;
    const expected_ps: u32 = 727;
    const expected_hz: u32 = 10027;

    if (time_ns != expected_ns or time_under_1_ns != expected_ps or getFrequency() != expected_hz) {
        panic(@errorReturnTrace(), "FAILURE: Frequency not set properly. Hz: {}!={}, ns: {}!={}, ps: {}!= {}\n", .{
            getFrequency(),
            expected_hz,
            time_ns,
            expected_ns,
            time_under_1_ns,
            expected_ps,
        });
    }

    var irq_exists = false;

    irq.registerIrq(pic.IRQ_PIT, pitHandler) catch |err| switch (err) {
        error.IrqExists => {
            // We should get this error
            irq_exists = true;
        },
        error.InvalidIrq => {
            panic(@errorReturnTrace(), "FAILURE: IRQ for PIT, IRQ number: {} is invalid", .{pic.IRQ_PIT});
        },
    };

    if (!irq_exists) {
        panic(@errorReturnTrace(), "FAILURE: IRQ for PIT doesn't exists\n", .{});
    }

    const expected_mode = OCW_READ_LOAD_DATA | OCW_MODE_SQUARE_WAVE_GENERATOR | OCW_SELECT_COUNTER_0 | OCW_BINARY_COUNT_BINARY;
    const actual_mode = readBackCommand(CounterSelect.Counter0);

    if (expected_mode != actual_mode) {
        panic(@errorReturnTrace(), "FAILURE: Operating mode don't not set properly. Found: {}, expecting: {}\n", .{ actual_mode, expected_mode });
    }

    log.info("Tested init\n", .{});
}

///
/// Run all the runtime tests.
///
pub fn runtimeTests() void {
    // Interrupts aren't enabled yet, so for the runtime tests, enable it temporary
    arch.enableInterrupts();
    defer arch.disableInterrupts();

    rt_initCounter_0();
    rt_waitTicks();
    rt_waitTicks2();
}
