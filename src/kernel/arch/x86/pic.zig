const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");
const log = if (is_test) @import(mock_path ++ "log_mock.zig") else @import("../../log.zig");
const panic = if (is_test) @import(mock_path ++ "panic_mock.zig").panic else @import("../../panic.zig").panic;

// ----------
// Port address for the PIC master and slave registers.
// ----------

/// The port address for issuing a command to the master PIC. This is a write only operation.
const MASTER_COMMAND_REG: u16 = 0x20;

/// The port address for reading one of the status register of the master PIC. This can be either
/// the In-Service Register (ISR) or the Interrupt Request Register (IRR). This is a read only
/// operation.
const MASTER_STATUS_REG: u16 = 0x20;

/// The port address for reading or writing to the data register of the master PIC. This can be
/// used in conjunction with the command register to set up the PIC. This can also be used to mask
/// the interrupt lines so interrupts can be issued to the CPU.
const MASTER_DATA_REG: u16 = 0x21;

/// The port address for issuing a command to the slave PIC. This is a write only operation.
const SLAVE_COMMAND_REG: u16 = 0xA0;

/// The port address for reading one of the status register of the slave PIC. This can be either
/// the In-Service Register (ISR) or the Interrupt Request Register (IRR). This is a read only
/// operation.
const SLAVE_STATUS_REG: u16 = 0xA0;

/// The port address for reading or writing to the data register of the status PIC. This can be
/// used in conjunction with the command register to set up the PIC. This can also be used to mask
/// the interrupt lines so interrupts can be issued to the CPU.
const SLAVE_DATA_REG: u16 = 0xA1;

// ----------
// Initialisation control word 1.
// ----------

/// Initialisation control word 1. Primary control word for initialising the PIC. If set, then the
/// PIC expects to receive a initialisation control word 4.
const ICW1_EXPECT_ICW4: u8 = 0x01;

/// If set, then there is only one PIC in the system. If not set, then PIC is cascaded with slave
/// PICs and initialisation control word 3 must be sent to the controller.
const ICW1_SINGLE_CASCADE_MODE: u8 = 0x02;

/// If set, then the internal CALL address is 4. If not set, then is 8. Usually ignored by x86. So
/// default is not set, 0.
const ICW1_CALL_ADDRESS_INTERVAL_4: u8 = 0x04;

/// If set, then operating in level triggered mode. If not set, then operating in edge triggered
/// mode.
const ICW1_LEVEL_TRIGGER_MODE: u8 = 0x08;

/// If set, then the PIC is to be initialised.
const ICW1_INITIALISATION: u8 = 0x10;

// ----------
// Initialisation control word 2.
// ----------

/// Initialisation control word 2. Map the base address of the interrupt vector table. The new port
/// map for the master PIC. IRQs 0-7 mapped to use interrupts 0x20-0x27.
const ICW2_MASTER_REMAP_OFFSET: u8 = 0x20;

/// The new port map for the slave PIC. IRQs 8-15 mapped to use interrupts 0x28-0x2F.
const ICW2_SLAVE_REMAP_OFFSET: u8 = 0x28;

// ----------
// Initialisation control word 3.
// ----------

/// Initialisation control word 3. For Telling the master and slave where the cascading. interrupts
/// are coming from. Tell the slave PIT to send interrupts to the master PIC on IRQ2.
const ICW3_SLAVE_IRQ_MAP_TO_MASTER: u8 = 0x02;

/// Tell the master PIT to receive interrupts from the slave PIC on IRQ2.
const ICW3_MASTER_IRQ_MAP_FROM_SLAVE: u8 = 0x04;

// ----------
// Initialisation control word 4.
// ----------

/// Initialisation control word 4. Tell the master and slave what mode to operate in. If set, then
/// in 80x86 mode. If not set, then in MCS-80/86 mode.
const ICW4_80x86_MODE: u8 = 0x01;

/// If set, then on last interrupt acknowledge pulse the PIC automatically performs end of
/// interrupt operation.
const ICW4_AUTO_END_OF_INTERRUPT: u8 = 0x02;

/// Only use if ICW4_BUFFER_MODE is set. If set, then selects master's buffer. If not set then uses
/// slave's buffer.
const ICW4_BUFFER_SELECT: u8 = 0x04;

/// If set, then PIC operates in buffered mode.
const ICW4_BUFFER_MODE: u8 = 0x08;

/// If set, then the the system had many cascaded PICs. Not supported in x86.
const ICW4_FULLY_NESTED_MODE: u8 = 0x10;

// ----------
// Operation control word 1.
// ----------

/// Operation control word 1. Interrupt masks for IRQ0 and IRQ8.
const OCW1_MASK_IRQ0_8: u8 = 0x01;

/// Operation control word 1. Interrupt masks for IRQ1 and IRQ9.
const OCW1_MASK_IRQ1_9: u8 = 0x02;

/// Operation control word 1. Interrupt masks for IRQ2 and IRQ10.
const OCW1_MASK_IRQ2_10: u8 = 0x04;

/// Operation control word 1. Interrupt masks for IRQ3 and IRQ11.
const OCW1_MASK_IRQ3_11: u8 = 0x08;

/// Operation control word 1. Interrupt masks for IRQ4 and IRQ12.
const OCW1_MASK_IRQ4_12: u8 = 0x10;

/// Operation control word 1. Interrupt masks for IRQ5 and IRQ13.
const OCW1_MASK_IRQ5_13: u8 = 0x20;

/// Operation control word 1. Interrupt masks for IRQ6 and IRQ14.
const OCW1_MASK_IRQ6_14: u8 = 0x40;

/// Operation control word 1. Interrupt masks for IRQ7 and IRQ15.
const OCW1_MASK_IRQ7_15: u8 = 0x80;

// ----------
// Operation control word 2.
// ----------

/// Operation control word 2. Primary commands for the PIC. Interrupt level 1 upon which the
/// controller must react. Interrupt level for the current interrupt.
const OCW2_INTERRUPT_LEVEL_1: u8 = 0x01;

/// Interrupt level 2 upon which the controller must react. Interrupt level for the current
/// interrupt
const OCW2_INTERRUPT_LEVEL_2: u8 = 0x02;

/// Interrupt level 3 upon which the controller must react. Interrupt level for the current
/// interrupt
const OCW2_INTERRUPT_LEVEL_3: u8 = 0x04;

/// The end of interrupt command code.
const OCW2_END_OF_INTERRUPT: u8 = 0x20;

/// Select command.
const OCW2_SELECTION: u8 = 0x40;

/// Rotation command.
const OCW2_ROTATION: u8 = 0x80;

// ----------
// Operation control word 3.
// ----------

/// Operation control word 3.
/// Read the Interrupt Request Register register
const OCW3_READ_IRR: u8 = 0x00;

/// Read the In Service Register register.
const OCW3_READ_ISR: u8 = 0x01;

/// If set, then bit 0 will be acted on, so read ISR or IRR. If not set, then no action taken.
const OCW3_ACT_ON_READ: u8 = 0x02;

/// If set, then poll command issued. If not set, then no pool command issued.
const OCW3_POLL_COMMAND_ISSUED: u8 = 0x04;

/// This must be set for all OCW 3.
const OCW3_DEFAULT: u8 = 0x08;

// Next bit must be zero.

/// If set, then the special mask is set. If not set, then resets special mask.
const OCW3_SPECIAL_MASK: u8 = 0x20;

/// If set, then bit 5 will be acted on, so setting the special mask. If not set, then no action it
/// taken.
const OCW3_ACK_ON_SPECIAL_MASK: u8 = 0x40;

// Last bit must be zero.

// ----------
// The IRQs
// ----------

/// The IRQ for the PIT.
pub const IRQ_PIT: u8 = 0x00;

/// The IRQ for the keyboard.
pub const IRQ_KEYBOARD: u8 = 0x01;

/// The IRQ for the cascade from master to slave.
pub const IRQ_CASCADE_FOR_SLAVE: u8 = 0x02;

/// The IRQ for the serial COM2/4.
pub const IRQ_SERIAL_PORT_2: u8 = 0x03;

/// The IRQ for the serial COM1/3.
pub const IRQ_SERIAL_PORT_1: u8 = 0x04;

/// The IRQ for the parallel port 2.
pub const IRQ_PARALLEL_PORT_2: u8 = 0x05;

/// The IRQ for the floppy disk.
pub const IRQ_DISKETTE_DRIVE: u8 = 0x06;

/// The IRQ for the parallel port 1.
pub const IRQ_PARALLEL_PORT_1: u8 = 0x07;

/// The IRQ for the CMOS real time clock (RTC).
pub const IRQ_REAL_TIME_CLOCK: u8 = 0x08;

/// The IRQ for the CGA vertical retrace.
pub const IRQ_CGA_VERTICAL_RETRACE: u8 = 0x09;

/// Reserved.
pub const IRQ_RESERVED1: u8 = 0x0A;

/// Reserved.
pub const IRQ_RESERVED2: u8 = 0x0B;

// The IRQ for the PS/2 mouse.
pub const IRQ_PS2_MOUSE: u8 = 0x0C;

/// The IRQ for the floating point unit/co-processor.
pub const IRQ_FLOATING_POINT_UNIT: u8 = 0x0D;

/// The IRQ for the primary hard drive controller.
pub const IRQ_PRIMARY_HARD_DISK_CONTROLLER: u8 = 0x0E;

/// The IRQ for the secondary hard drive controller.
pub const IRQ_SECONDARY_HARD_DISK_CONTROLLER: u8 = 0x0F;

/// Keep track of the number of spurious IRQs.
var spurious_irq_counter: u32 = 0;

///
/// Send a command to the master PIC. This will send it to the master command port.
///
/// Arguments:
///     IN cmd: u8 - The command to send.
///
inline fn sendCommandMaster(cmd: u8) void {
    arch.outb(MASTER_COMMAND_REG, cmd);
}

///
/// Send a command to the salve PIC. This will send it to the salve command port.
///
/// Arguments:
///     IN cmd: u8 - The command to send.
///
inline fn sendCommandSlave(cmd: u8) void {
    arch.outb(SLAVE_COMMAND_REG, cmd);
}

///
/// Send data to the master PIC. This will send it to the master data port.
///
/// Arguments:
///     IN data: u8 - The data to send.
///
inline fn sendDataMaster(data: u8) void {
    arch.outb(MASTER_DATA_REG, data);
}

///
/// Send data to the salve PIC. This will send it to the salve data port.
///
/// Arguments:
///     IN data: u8 - The data to send.
///
inline fn sendDataSlave(data: u8) void {
    arch.outb(SLAVE_DATA_REG, data);
}

///
/// Read the data from the master data register. This will read from the master data port.
///
/// Return: u8
///     The data that is stored in the master data register.
///
inline fn readDataMaster() u8 {
    return arch.inb(MASTER_DATA_REG);
}

///
/// Read the data from the salve data register. This will read from the salve data port.
///
/// Return: u8
///     The data that is stored in the salve data register.
///
inline fn readDataSlave() u8 {
    return arch.inb(SLAVE_DATA_REG);
}

///
/// Read the master interrupt request register (IRR).
///
/// Return: u8
///     The data that is stored in the master IRR.
///
inline fn readMasterIrr() u8 {
    sendCommandMaster(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_IRR);
    return arch.inb(MASTER_STATUS_REG);
}

///
/// Read the slave interrupt request register (IRR).
///
/// Return: u8
///     The data that is stored in the slave IRR.
///
inline fn readSlaveIrr() u8 {
    sendCommandSlave(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_IRR);
    return arch.inb(SLAVE_STATUS_REG);
}

///
/// Read the master in-service register (ISR).
///
/// Return: u8
///     The data that is stored in the master ISR.
///
inline fn readMasterIsr() u8 {
    sendCommandMaster(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_ISR);
    return arch.inb(MASTER_STATUS_REG);
}

///
/// Read the slave in-service register (ISR).
///
/// Return: u8
///     The data that is stored in the slave ISR.
///
inline fn readSlaveIsr() u8 {
    sendCommandSlave(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_ISR);
    return arch.inb(SLAVE_STATUS_REG);
}

///
/// Send the end of interrupt (EOI) signal to the PIC. If the IRQ was from the master, then will
/// send the EOI to the master only. If the IRQ came from the slave, then will send the EOI to both
/// the slave and master.
///
/// Arguments:
///     IN irq_num: u8 - The IRQ number to sent the EOI to.
///
pub fn sendEndOfInterrupt(irq_num: u8) void {
    if (irq_num >= 8) {
        sendCommandSlave(OCW2_END_OF_INTERRUPT);
    }

    sendCommandMaster(OCW2_END_OF_INTERRUPT);
}

///
/// Check if the interrupt was a fake interrupt. (In short, this stops a race condition between the
/// CPU and PIC. See https://wiki.osdev.org/PIC#Spurious_IRQs for more details). If this returns
/// true, then the IRQ handler must not send a EOI back.
///
/// Arguments:
///     IN irq_num: u8 - The IRQ number to check.
///
/// Return: bool
///     Whether the IRQ provided was spurious.
///
pub fn spuriousIrq(irq_num: u8) bool {
    // Only for IRQ 7 and 15
    if (irq_num == 7) {
        // Read master ISR
        // Check the MSB is zero, if so, then is a spurious IRQ
        // This is (1 << irq_num) or (1 << 7) to check if it is set for this IRQ
        if ((readMasterIsr() & 0x80) == 0) {
            spurious_irq_counter += 1;
            return true;
        }
    } else if (irq_num == 15) {
        // Read slave ISR
        // Check the MSB is zero, if so, then is a spurious irq
        if ((readSlaveIsr() & 0x80) == 0) {
            // Need to send EOI to the master
            sendCommandMaster(OCW2_END_OF_INTERRUPT);
            spurious_irq_counter += 1;
            return true;
        }
    }

    return false;
}

///
/// Set the mask bit for the provided IRQ. This will prevent interrupts from triggering for this
/// IRQ.
///
/// Arguments:
///     IN irq_num: u8 - The IRQ number to mask.
///
pub fn setMask(irq_num: u8) void {
    const port: u16 = if (irq_num < 8) MASTER_DATA_REG else SLAVE_DATA_REG;
    const shift = @intCast(u3, irq_num % 8);
    const value: u8 = arch.inb(port) | (@as(u8, 1) << shift);
    arch.outb(port, value);
}

///
/// Clear the mask bit for the provided IRQ. This will allow interrupts to triggering for this IRQ.
///
/// Arguments:
///     IN irq_num: u8 - The IRQ number unmask.
///
pub fn clearMask(irq_num: u8) void {
    const port: u16 = if (irq_num < 8) MASTER_DATA_REG else SLAVE_DATA_REG;
    const shift = @intCast(u3, irq_num % 8);
    const value: u8 = arch.inb(port) & ~(@as(u8, 1) << shift);
    arch.outb(port, value);
}

///
/// Remap the PIC interrupt lines as initially they conflict with CPU exceptions which are reserved
/// by Intel up to 0x1F. So this will move the IRQs from 0x00-0x0F to 0x20-0x2F.
///
pub fn init() void {
    log.logInfo("Init pic\n", .{});

    // Initiate
    sendCommandMaster(ICW1_INITIALISATION | ICW1_EXPECT_ICW4);
    arch.ioWait();
    sendCommandSlave(ICW1_INITIALISATION | ICW1_EXPECT_ICW4);
    arch.ioWait();

    // Offsets
    sendDataMaster(ICW2_MASTER_REMAP_OFFSET);
    arch.ioWait();
    sendDataSlave(ICW2_SLAVE_REMAP_OFFSET);
    arch.ioWait();

    // IRQ lines
    sendDataMaster(ICW3_MASTER_IRQ_MAP_FROM_SLAVE);
    arch.ioWait();
    sendDataSlave(ICW3_SLAVE_IRQ_MAP_TO_MASTER);
    arch.ioWait();

    // 80x86 mode
    sendDataMaster(ICW4_80x86_MODE);
    arch.ioWait();
    sendDataSlave(ICW4_80x86_MODE);
    arch.ioWait();

    // Mask all interrupts
    sendDataMaster(0xFF);
    arch.ioWait();
    sendDataSlave(0xFF);
    arch.ioWait();

    // Clear the IRQ for the slave
    clearMask(IRQ_CASCADE_FOR_SLAVE);

    log.logInfo("Done\n", .{});

    if (build_options.rt_test) runtimeTests();
}

test "sendCommandMaster" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    const cmd: u8 = 10;

    arch.addTestParams("outb", .{ MASTER_COMMAND_REG, cmd });

    sendCommandMaster(cmd);
}

test "sendCommandSlave" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    const cmd: u8 = 10;

    arch.addTestParams("outb", .{ SLAVE_COMMAND_REG, cmd });

    sendCommandSlave(cmd);
}

test "sendDataMaster" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    const data: u8 = 10;

    arch.addTestParams("outb", .{ MASTER_DATA_REG, data });

    sendDataMaster(data);
}

test "sendDataSlave" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    const data: u8 = 10;

    arch.addTestParams("outb", .{ SLAVE_DATA_REG, data });

    sendDataSlave(data);
}

test "readDataMaster" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("inb", .{ MASTER_DATA_REG, @as(u8, 10) });

    expectEqual(@as(u8, 10), readDataMaster());
}

test "readDataSlave" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("inb", .{ SLAVE_DATA_REG, @as(u8, 10) });

    expectEqual(@as(u8, 10), readDataSlave());
}

test "readMasterIrr" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb", .{ MASTER_COMMAND_REG, @as(u8, 0x0A) });
    arch.addTestParams("inb", .{ MASTER_STATUS_REG, @as(u8, 10) });

    expectEqual(@as(u8, 10), readMasterIrr());
}

test "readSlaveIrr" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb", .{ SLAVE_COMMAND_REG, @as(u8, 0x0A) });
    arch.addTestParams("inb", .{ SLAVE_STATUS_REG, @as(u8, 10) });

    expectEqual(@as(u8, 10), readSlaveIrr());
}

test "readMasterIsr" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb", .{ MASTER_COMMAND_REG, @as(u8, 0x0B) });
    arch.addTestParams("inb", .{ MASTER_STATUS_REG, @as(u8, 10) });

    expectEqual(@as(u8, 10), readMasterIsr());
}

test "readSlaveIsr" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb", .{ SLAVE_COMMAND_REG, @as(u8, 0x0B) });
    arch.addTestParams("inb", .{ SLAVE_STATUS_REG, @as(u8, 10) });

    expectEqual(@as(u8, 10), readSlaveIsr());
}

test "sendEndOfInterrupt master only" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        arch.addTestParams("outb", .{ MASTER_COMMAND_REG, OCW2_END_OF_INTERRUPT });

        sendEndOfInterrupt(i);
    }
}

test "sendEndOfInterrupt master and slave" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    var i: u8 = 8;
    while (i < 16) : (i += 1) {
        arch.addTestParams("outb", .{ SLAVE_COMMAND_REG, OCW2_END_OF_INTERRUPT });
        arch.addTestParams("outb", .{ MASTER_COMMAND_REG, OCW2_END_OF_INTERRUPT });

        sendEndOfInterrupt(i);
    }
}

test "spuriousIrq not spurious IRQ number" {
    // Pre testing
    expectEqual(@as(u32, 0), spurious_irq_counter);

    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        if (i != 7 and i != 15) {
            expectEqual(false, spuriousIrq(i));
        }
    }

    // Post testing
    expectEqual(@as(u32, 0), spurious_irq_counter);

    // Clean up
    spurious_irq_counter = 0;
}

test "spuriousIrq spurious master IRQ number not spurious" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb", .{ MASTER_COMMAND_REG, @as(u8, 0x0B) });
    // Return 0x80 from readMasterIsr() which will mean this was a real IRQ
    arch.addTestParams("inb", .{ MASTER_STATUS_REG, @as(u8, 0x80) });

    // Pre testing
    expectEqual(@as(u32, 0), spurious_irq_counter);

    // Call function
    expectEqual(false, spuriousIrq(7));

    // Post testing
    expectEqual(@as(u32, 0), spurious_irq_counter);

    // Clean up
    spurious_irq_counter = 0;
}

test "spuriousIrq spurious master IRQ number spurious" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb", .{ MASTER_COMMAND_REG, @as(u8, 0x0B) });
    // Return 0x0 from readMasterIsr() which will mean this was a spurious IRQ
    arch.addTestParams("inb", .{ MASTER_STATUS_REG, @as(u8, 0x0) });

    // Pre testing
    expectEqual(@as(u32, 0), spurious_irq_counter);

    // Call function
    expectEqual(true, spuriousIrq(7));

    // Post testing
    expectEqual(@as(u32, 1), spurious_irq_counter);

    // Clean up
    spurious_irq_counter = 0;
}

test "spuriousIrq spurious slave IRQ number not spurious" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb", .{ SLAVE_COMMAND_REG, @as(u8, 0x0B) });
    // Return 0x80 from readSlaveIsr() which will mean this was a real IRQ
    arch.addTestParams("inb", .{ SLAVE_STATUS_REG, @as(u8, 0x80) });

    // Pre testing
    expectEqual(@as(u32, 0), spurious_irq_counter);

    // Call function
    expectEqual(false, spuriousIrq(15));

    // Post testing
    expectEqual(@as(u32, 0), spurious_irq_counter);

    // Clean up
    spurious_irq_counter = 0;
}

test "spuriousIrq spurious slave IRQ number spurious" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb", .{ SLAVE_COMMAND_REG, @as(u8, 0x0B) });
    // Return 0x0 from readSlaveIsr() which will mean this was a spurious IRQ
    arch.addTestParams("inb", .{ SLAVE_STATUS_REG, @as(u8, 0x0) });
    // A EOI will be sent for a spurious IRQ 15
    arch.addTestParams("outb", .{ MASTER_COMMAND_REG, OCW2_END_OF_INTERRUPT });

    // Pre testing
    expectEqual(@as(u32, 0), spurious_irq_counter);

    // Call function
    expectEqual(true, spuriousIrq(15));

    // Post testing
    expectEqual(@as(u32, 1), spurious_irq_counter);

    // Clean up
    spurious_irq_counter = 0;
}

test "setMask master IRQ masked" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    // Going to assume all bits are masked out
    arch.addTestParams("inb", .{ MASTER_DATA_REG, @as(u8, 0xFF) });
    // Expect the 2nd bit to be set
    arch.addTestParams("outb", .{ MASTER_DATA_REG, @as(u8, 0xFF) });

    setMask(1);
}

test "setMask master IRQ unmasked" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    // IRQ already unmasked
    arch.addTestParams("inb", .{ MASTER_DATA_REG, @as(u8, 0xFD) });
    // Expect the 2nd bit to be set
    arch.addTestParams("outb", .{ MASTER_DATA_REG, @as(u8, 0xFF) });

    setMask(1);
}

test "clearMask master IRQ masked" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    // Going to assume all bits are masked out
    arch.addTestParams("inb", .{ MASTER_DATA_REG, @as(u8, 0xFF) });
    // Expect the 2nd bit to be clear
    arch.addTestParams("outb", .{ MASTER_DATA_REG, @as(u8, 0xFD) });

    clearMask(1);
}

test "clearMask master IRQ unmasked" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    // IRQ already unmasked
    arch.addTestParams("inb", .{ MASTER_DATA_REG, @as(u8, 0xFD) });
    // Expect the 2nd bit to still be clear
    arch.addTestParams("outb", .{ MASTER_DATA_REG, @as(u8, 0xFD) });

    clearMask(1);
}

test "init" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addRepeatFunction("ioWait", arch.mock_ioWait);

    // Just a long list of OUT instructions setting up the PIC
    arch.addTestParams("outb", .{
        MASTER_COMMAND_REG,
        ICW1_INITIALISATION | ICW1_EXPECT_ICW4,
        SLAVE_COMMAND_REG,
        ICW1_INITIALISATION | ICW1_EXPECT_ICW4,
        MASTER_DATA_REG,
        ICW2_MASTER_REMAP_OFFSET,
        SLAVE_DATA_REG,
        ICW2_SLAVE_REMAP_OFFSET,
        MASTER_DATA_REG,
        ICW3_MASTER_IRQ_MAP_FROM_SLAVE,
        SLAVE_DATA_REG,
        ICW3_SLAVE_IRQ_MAP_TO_MASTER,
        MASTER_DATA_REG,
        ICW4_80x86_MODE,
        SLAVE_DATA_REG,
        ICW4_80x86_MODE,
        MASTER_DATA_REG,
        @as(u8, 0xFF),
        SLAVE_DATA_REG,
        @as(u8, 0xFF),
        MASTER_DATA_REG,
        @as(u8, 0xFB),
    });

    arch.addTestParams("inb", .{ MASTER_DATA_REG, @as(u8, 0xFF) });

    init();
}

///
/// Test that all the PIC masks are set so no interrupts can fire.
///
fn rt_picAllMasked() void {
    // The master will have interrupt 2 clear because this is the link to the slave (third bit)
    if (readDataMaster() != 0xFB) {
        panic(@errorReturnTrace(), "Master masks are not set, found: {}\n", .{readDataMaster()});
    }

    if (readDataSlave() != 0xFF) {
        panic(@errorReturnTrace(), "Slave masks are not set, found: {}\n", .{readDataSlave()});
    }

    log.logInfo("PIC: Tested masking\n", .{});
}

///
/// Run all the runtime tests.
///
fn runtimeTests() void {
    rt_picAllMasked();
}
