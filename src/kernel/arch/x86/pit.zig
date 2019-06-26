// Zig version: 0.4.0

const arch = @import("arch.zig");
const assert = @import("std").debug.assert;
const irq = @import("irq.zig");
const pic = @import("pic.zig");
const log = @import("../../log.zig");

// The port addresses of the PIT registers
/// The port address for the PIT data register for counter 0. This is going to be used as the
/// system clock.
const COUNTER_0_REGISTER: u16   = 0x40;

/// The port address for the PIT data register for counter 1. This was used for refreshing the DRAM
/// chips. But now is unused and unknown use, so won't use.
const COUNTER_1_REGISTER: u16   = 0x41;

/// The port address for the PIT data register for counter 2. Connected to the PC speakers, we'll
/// use this for the speakers.
const COUNTER_2_REGISTER: u16   = 0x42;

/// The port address for the PIT control word register. Used to tell the PIT controller what is
/// about to happen. Tell what data is going where, lower or upper part of it's registers.
const COMMAND_REGISTER: u16     = 0x43;

// The operational command word marks for the different modes.
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
const OCW_BINARY_COUNT_BINARY: u8           = 0x00; // xxxxxxx0

/// Have the counter count in BCD (internally?).
const OCW_BINARY_COUNT_BCD: u8              = 0x01; // xxxxxxx1

/// The PIT counter will be programmed with an initial COUNT value that counts down at a rate of
/// the input clock frequency. When the COUNT reaches 0, and after the control word is written,
/// then its OUT pit is set high (1). Count down starts then the COUNT is set. The OUT pin remains
/// high until the counter is reloaded with a new COUNT value or a new control work is written.
const OCW_MODE_TERMINAL_COUNT: u8           = 0x00; // xxxx000x

/// The counter is programmed to output a pulse every curtain number of clock pulses. The OUT pin
/// remains high as soon as a control word is written. When COUNT is written, the counter waits
/// until the rising edge of the GATE pin to start.  One clock pulse after the GATE pin, the OUT
/// pin will remain low until COUNT reaches 0.
const OCW_MODE_ONE_SHOT: u8                 = 0x02; // xxxx001x

/// The counter is initiated with a COUNT value. Counting starts next clock pulse. OUT pin remains
/// high until COUNT reaches 1, then is set low for one clock pulse. Then COUNT is reset back to
/// initial value and OUT pin is set high again.
const OCW_MODE_RATE_GENERATOR: u8           = 0x04; // xxxx010x

/// Similar to PIT_OCW_MODE_RATE_GENERATOR, but OUT pin will be high for half the time and low for
/// half the time. Good for the speaker when setting a tone.
const OCW_MODE_SQUARE_WAVE_GENERATOR: u8    = 0x06; // xxxx011x

/// The counter is initiated with a COUNT value. Counting starts on next clock pulse. OUT pin remains
/// high until count is 0. Then OUT pin is low for one clock pulse. Then resets to high again.
const OCW_MODE_SOFTWARE_TRIGGER: u8         = 0x08; // xxxx100x

/// The counter is initiated with a COUNT value. OUT pin remains high until the rising edge of the
/// GATE pin. Then the counting begins. When COUNT reaches 0, OUT pin goes low for one clock pulse.
/// Then COUNT is reset and OUT pin goes high. This cycles for each rising edge of the GATE pin.
const OCW_MODE_HARDWARE_TRIGGER: u8         = 0x0A; // xxxx101x

/// The counter value is latched into an internal control register at the time of the I/O write
/// operations.
const OCW_READ_LOAD_LATCH: u8               = 0x00; // xx00xxxx

/// Read or load the most significant bit only.
const OCW_READ_LOAD_LSB_ONLY: u8            = 0x10; // xx01xxxx

/// Read or load the least significant bit only.
const OCW_READ_LOAD_MSB_ONLY: u8            = 0x20; // xx10xxxx

/// Read or load the least significant bit first then the most significant bit.
const OCW_READ_LOAD_DATA: u8                = 0x30; // xx11xxxx

/// The OCW bits for selecting counter 0. Used for the system clock.
const OCW_SELECT_COUNTER_0: u8              = 0x00; // 00xxxxxx

/// The OCW bits for selecting counter 1. Was for the memory refreshing.
const OCW_SELECT_COUNTER_1: u8              = 0x40; // 01xxxxxx

/// The OCW bits for selecting counter 2. Channel for the speaker.
const OCW_SELECT_COUNTER_2: u8              = 0x80; // 10xxxxxx

// The divisor constant
const MAX_FREQUENCY: u32 = 1193180;

/// The number of ticks that has passed when counter 0 was initially set up.
var ticks: u32 = 0;

/// The number of tick that has passed when counter 1 was initially set up.
var ram_ticks: u32 = 0;

/// The number of tick that has passed when counter 2 was initially set up.
var speaker_ticks: u32 = 0;

// The current frequency of counter 0
var current_freq_0: u32 = undefined;

// The current frequency of counter 1
var current_freq_1: u32 = undefined;

// The current frequency of counter 2
var current_freq_2: u32 = undefined;

var time_ms: u32 = undefined;
var time_under_1_ms: u32 = undefined;

///
/// Send a command to the PIT command register.
///
/// Arguments:
///     IN cmd: u8 - The command to send to the PIT.
///
inline fn sendCommand(cmd: u8) void {
    arch.outb(COMMAND_REGISTER, cmd);
}

///
/// Send data to a given counter. Will be only one of the 3 counters as is an internal function.
///
/// Arguments:
///     IN comptime counter: u16 - The counter port to send the data to.
///     IN data: u8              - The data to send.
///
inline fn sendDateToCounter(comptime counter: u16, data: u8) void {
    assert(counter == COUNTER_0_REGISTER or counter == COUNTER_1_REGISTER or counter == COUNTER_2_REGISTER);
    arch.outb(counter, data);
}

fn pitHandler(context: *arch.InterruptContext) void {
    ticks += 1;
}

///
/// Set up a counter with a tick rate and mode of operation.
///
/// Arguments:
///     IN freq: u16   - The frequency that the counter operates at.
///     IN counter: u8 - Which counter is to be set up, either OCW_SELECT_COUNTER_0,
///                      OCW_SELECT_COUNTER_1 or OCW_SELECT_COUNTER_2 only.
///     IN mode: u8    - The mode of operation that the counter will operate in. See The modes
///                      definition above to chose which mode the counter is to run at.
///
fn setupCounter(comptime counter: u8, freq: u32, mode: u8) void {
    var reload_value: u32 = 0x10000; // 65536, the slowest possible frequency

    if (freq > 18) {
        // The fastest possible frequency if frequency is too high
        reload_value = 1;

        if (freq < MAX_FREQUENCY) {
            reload_value = MAX_FREQUENCY / freq;
            var rem: u32 = MAX_FREQUENCY % freq;

            // Is the remainder more than half
            if (rem > MAX_FREQUENCY / 2) {
                // Round up
                reload_value += 1;
            }
        }
    }

    // Get the u16 version as this is what will be loaded into the PIT
    var reload_val_16: u16 = @truncate(u16, reload_value);

    // Update the frequency with the actual one that the PIT will be using
    var frequency: u32 = MAX_FREQUENCY / reload_value;
    var rem: u32 = MAX_FREQUENCY % reload_value;

    // Is the remainder more than half
    if (rem > MAX_FREQUENCY / 2) {
        // Round up
        frequency += 1;
    }

    // Calculate the amount of time between IRQs
    time_ms = reload_value * u32(1000);
    time_under_1_ms = time_ms % MAX_FREQUENCY;
    time_ms /= MAX_FREQUENCY;

    comptime const port: u16 = switch (counter) {
        OCW_SELECT_COUNTER_0 => COUNTER_0_REGISTER,
        OCW_SELECT_COUNTER_1 => COUNTER_1_REGISTER,
        OCW_SELECT_COUNTER_2 => COUNTER_2_REGISTER,
        else => unreachable,
    };

    switch (counter) {
        OCW_SELECT_COUNTER_0 => current_freq_0 = frequency,
        OCW_SELECT_COUNTER_1 => current_freq_1 = frequency,
        OCW_SELECT_COUNTER_2 => current_freq_2 = frequency,
        else => unreachable,
    }

    var command: u8 = mode | OCW_READ_LOAD_DATA | counter;

    sendCommand(command);

    sendDateToCounter(port, @truncate(u8, reload_val_16));
    sendDateToCounter(port, @truncate(u8, reload_val_16 >> 8));

    // Reset the counter ticks
    switch (counter) {
        OCW_SELECT_COUNTER_0 => ticks = 0,
        OCW_SELECT_COUNTER_1 => ram_ticks = 0,
        OCW_SELECT_COUNTER_2 => speaker_ticks = 0,
        else => unreachable,
    }
}

///
/// A simple wait that used the PIT to wait a number of ticks.
///
/// Arguments:
///     IN milliseconds: u32 - The number of ticks to wait.
///
pub fn waitTicks(ticks_to_wait: u32) void {
    const wait_ticks = ticks + ticks_to_wait;
    while (ticks < wait_ticks) {
        arch.enableInterrupts();
        arch.halt();
        arch.disableInterrupts();
    }
    arch.enableInterrupts();
}

///
/// Get the number of ticks that have passed when the PIT was initiated.
///
/// Return:
///     Number of ticks passed.
///
pub fn getTicks() u32 {
    return ticks;
}

///
/// Get the frequency the PIT is ticking at.
///
/// Return:
///     The frequency the PIT is running at
///
pub fn getFrequency() u32 {
    return current_freq_0;
}

///
/// Initialise the PIT with a handler to IRQ 0.
///
pub fn init() void {
    // Set up counter 0 at 1000hz in a square wave mode counting in binary
    const f: u32 = 10000;
    setupCounter(OCW_SELECT_COUNTER_0, f, OCW_MODE_SQUARE_WAVE_GENERATOR | OCW_BINARY_COUNT_BINARY);

    log.logInfo("Set frequency at: {}Hz, real frequency: {}Hz\n", f, getFrequency());

    // Installs 'pitHandler' to IRQ0 (pic.IRQ_PIT)
    irq.registerIrq(pic.IRQ_PIT, pitHandler);
}
