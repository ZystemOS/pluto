// Zig version: 0.4.0

const arch = @import("arch.zig");

// Port address for the PIC master and slave registers
const MASTER_COMMAND_REG: u16           = 0x20; // (Write only).
const MASTER_STATUS_REG: u16            = 0x20; // (Read only).
const MASTER_DATA_REG: u16              = 0x21;
const MASTER_INTERRUPT_MASK_REG: u16    = 0x21;
const SLAVE_COMMAND_REG: u16            = 0xA0; // (Write only).
const SLAVE_STATUS_REG: u16             = 0xA0; // (Read only).
const SLAVE_DATA_REG: u16               = 0xA1;
const SLAVE_INTERRUPT_MASK_REG: u16     = 0xA1;

// Initialisation control word 1. Primary control word for initialising the PIC.
// If set, then the PIC expects to receive a initialisation control word 4.
const ICW1_EXPECT_ICW4: u8              = 0x01;

// If set, then there is only one PIC in the system. If not set, then PIC is cascaded with slave
// PIC's and initialisation control word 3 must be sent to the controller.
const ICW1_SINGLE_CASCADE_MODE: u8      = 0x02;

// If set, then the internal CALL address is 4. If not set, then is 8. Usually ignored by x86.
// So default is not set, 0.
const ICW1_CALL_ADDRESS_INTERVAL_4: u8  = 0x04;

// If set, then operating in level triggered mode. If not set, then operating in edge triggered
// mode.
const ICW1_LEVEL_TRIGGER_MODE: u8       = 0x08;

// If set, then the PIC is to be initialised.
const ICW1_INITIALISATION: u8           = 0x10;


// Initialisation control word 2. Map the base address of the interrupt vector table.
// The new port map for the master PIC. IRQs 0-7 mapped to use interrupts 0x20-0x27
const ICW2_MASTER_REMAP_OFFSET: u8      = 0x20;

// The new port map for the slave PIC. IRQs 8-15 mapped to use interrupts 0x28-0x36
const ICW2_SLAVE_REMAP_OFFSET: u8       = 0x28;


// Initialisation control word 3. For Telling the master and slave where the cascading
// interrupts are coming from.
// Tell the slave PIT to send interrupts to the master PIC on IRQ2
const ICW3_SLAVE_IRQ_MAP_TO_MASTER: u8      = 0x02;

// Tell the master PIT to receive interrupts from the slave PIC on IRQ2
const ICW3_MASTER_IRQ_MAP_FROM_SLAVE: u8    = 0x04;


// Initialisation control word 4. Tell the master and slave what mode to operate in.
// If set, then in 80x86 mode. If not set, then in MCS-80/86 mode
const ICW4_80x86_MODE: u8               = 0x01;

// If set, then on last interrupt acknowledge pulse the PIC automatically performs end of
// interrupt operation.
const ICW4_AUTO_END_OF_INTERRUPT: u8    = 0x02;

// Only use if ICW4_BUFFER_MODE is set. If set, then selects master's buffer. If not set then uses
// slave's buffer.
const ICW4_BUFFER_SELECT: u8            = 0x04;

// If set, then PIC operates in buffered mode.
const ICW4_BUFFER_MODE: u8              = 0x08;

// If set, then the the system had many cascaded PIC's. Not supported in x86.
const ICW4_FULLY_NESTED_MODE: u8        = 0x10;


// Operation control word 1. Interrupt masks.
const OCW1_MASK_IRQ0: u8  = 0x01;
const OCW1_MASK_IRQ1: u8  = 0x02;
const OCW1_MASK_IRQ2: u8  = 0x04;
const OCW1_MASK_IRQ3: u8  = 0x08;
const OCW1_MASK_IRQ4: u8  = 0x10;
const OCW1_MASK_IRQ5: u8  = 0x20;
const OCW1_MASK_IRQ6: u8  = 0x40;
const OCW1_MASK_IRQ7: u8  = 0x80;

// Operation control word 2. Primary commands for the PIC.
// Interrupt level 1 upon which the controller must react. Interrupt level for the current interrupt
const OCW2_INTERRUPT_LEVEL_1: u8    = 0x01;

// Interrupt level 2 upon which the controller must react. Interrupt level for the current interrupt
const OCW2_INTERRUPT_LEVEL_2: u8    = 0x02;

// Interrupt level 3 upon which the controller must react. Interrupt level for the current interrupt
const OCW2_INTERRUPT_LEVEL_3: u8    = 0x04;

// The end of interrupt command code.
const OCW2_END_OF_INTERRUPT: u8     = 0x20;

// Select command.
const OCW2_SELECTION: u8            = 0x40;

// Rotation command.
const OCW2_ROTATION: u8             = 0x80;


// Operation control word 3.
// Read the Interrupt Request Register register
const OCW3_READ_IRR: u8             = 0x00;

// Read the In Service Register register.
const OCW3_READ_ISR: u8             = 0x01;

// If set, then bit 0 will be acted on, so read ISR or IRR. If not set, then no action taken.
const OCW3_ACT_ON_READ: u8          = 0x02;

// If set, then poll command issued. If not set, then no pool command issued.
const OCW3_POLL_COMMAND_ISSUED: u8  = 0x04;

// This must be set for all OCW 3.
const OCW3_DEFAULT: u8              = 0x08;

// If set, then the special mask is set. If not set, then resets special mask.
const OCW3_SPECIAL_MASK: u8         = 0x20;

// If set, then bit 5 will be acted on, so setting the special mask. If not set, then no action it
// taken.
const OCW3_ACK_ON_SPECIAL_MASK: u8  = 0x40;


// IRQ's numbers for the PIC.
pub const IRQ_PIT: u8                   = 0x00;
pub const IRQ_KEYBOARD: u8              = 0x01;
pub const IRQ_CASCADE_FOR_SLAVE: u8     = 0x02;
pub const IRQ_SERIAL_PORT_2: u8         = 0x03;
pub const IRQ_SERIAL_PORT_1: u8         = 0x04;
pub const IRQ_PARALLEL_PORT_2: u8       = 0x05;
pub const IRQ_DISKETTE_DRIVE: u8        = 0x06;
pub const IRQ_PARALLEL_PORT_1: u8       = 0x07;
pub const IRQ_REAL_TIME_CLOCK: u8       = 0x08;
pub const IRQ_CGA_VERTICAL_RETRACE: u8  = 0x09;

pub const IRQ_AUXILIARY_DEVICE: u8      = 0x0C;
pub const IRQ_FLOATING_POINT_UNIT: u8   = 0x0D;
pub const IRQ_HARD_DISK_CONTROLLER: u8  = 0x0E;


// Keep track of the number of spurious IRQ's
var spurious_irq_counter: u32 = 0;


inline fn sendCommandMaster(cmd: u8) void {
    arch.outb(MASTER_COMMAND_REG, cmd);
}

inline fn sendCommandSlave(cmd: u8) void {
    arch.outb(SLAVE_COMMAND_REG, cmd);
}

inline fn sendDataMaster(cmd: u8) void {
    arch.outb(MASTER_DATA_REG, cmd);
}

inline fn sendDataSlave(cmd: u8) void {
    arch.outb(SLAVE_DATA_REG, cmd);
}

inline fn readDataMaster() u8 {
    return arch.inb(MASTER_DATA_REG);
}

inline fn readDataSlave() u8 {
    return arch.inb(SLAVE_DATA_REG);
}

inline fn readMasterIrr() u8 {
    sendCommandSlave(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_IRR);
    return arch.inb(SLAVE_STATUS_REG);
}

inline fn readSlaveIrr() u8 {
    sendCommandMaster(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_IRR);
    return arch.inb(MASTER_STATUS_REG);
}

inline fn readMasterIsr() u8 {
    sendCommandSlave(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_ISR);
    return arch.inb(SLAVE_STATUS_REG);
}

inline fn readSlaveIsr() u8 {
    sendCommandMaster(OCW3_DEFAULT | OCW3_ACT_ON_READ | OCW3_READ_ISR);
    return arch.inb(MASTER_STATUS_REG);
}

pub fn sendEndOfInterrupt(irq_num: u8) void {
    if (irq_num >= 8) {
        sendCommandSlave(OCW2_END_OF_INTERRUPT);
    }

    sendCommandMaster(OCW2_END_OF_INTERRUPT);
}

pub fn spuriousIrq(irq_num: u8) bool {
    // Only for IRQ 7 and 15
    if(irq_num == 7) {
        // Read master ISR
        // Check the MSB is zero, if so, then is a spurious irq
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

pub fn setMask(irq_num: u16) void {
    const port: u16 = if (irq_num < 8) MASTER_DATA_REG else SLAVE_DATA_REG;
    const shift = @intCast(u3, irq_num % 8);
    const value: u8 = arch.inb(port) | (u8(1) << shift);
    arch.outb(port, value);
}

pub fn clearMask(irq_num: u16) void {
    const port: u16 = if (irq_num < 8) MASTER_DATA_REG else SLAVE_DATA_REG;
    const shift = @intCast(u3, irq_num % 8);
    const value: u8 = arch.inb(port) & ~(u8(1) << shift);
    arch.outb(port, value);
}

pub fn remapIrq() void {
    // Initiate
    sendCommandMaster(ICW1_INITIALISATION | ICW1_EXPECT_ICW4);
    sendCommandSlave(ICW1_INITIALISATION | ICW1_EXPECT_ICW4);

    // Offsets
    sendDataMaster(ICW2_MASTER_REMAP_OFFSET);
    sendDataSlave(ICW2_SLAVE_REMAP_OFFSET);

    // IRQ lines
    sendDataMaster(ICW3_MASTER_IRQ_MAP_FROM_SLAVE);
    sendDataSlave(ICW3_SLAVE_IRQ_MAP_TO_MASTER);

    // 80x86 mode
    sendDataMaster(ICW4_80x86_MODE);
    sendDataSlave(ICW4_80x86_MODE);

    // Mask
    arch.outb(0x21, 0xFF);
    arch.outb(0xA1, 0xFF);
}
