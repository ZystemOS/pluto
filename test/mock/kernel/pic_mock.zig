const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

const MASTER_COMMAND_REG: u16 = 0x20;
const MASTER_STATUS_REG: u16 = 0x20;
const MASTER_DATA_REG: u16 = 0x21;
const MASTER_INTERRUPT_MASK_REG: u16 = 0x21;
const SLAVE_COMMAND_REG: u16 = 0xA0;
const SLAVE_STATUS_REG: u16 = 0xA0;
const SLAVE_DATA_REG: u16 = 0xA1;
const SLAVE_INTERRUPT_MASK_REG: u16 = 0xA1;

const ICW1_EXPECT_ICW4: u8 = 0x01;
const ICW1_SINGLE_CASCADE_MODE: u8 = 0x02;
const ICW1_CALL_ADDRESS_INTERVAL_4: u8 = 0x04;
const ICW1_LEVEL_TRIGGER_MODE: u8 = 0x08;
const ICW1_INITIALISATION: u8 = 0x10;

const ICW2_MASTER_REMAP_OFFSET: u8 = 0x20;
const ICW2_SLAVE_REMAP_OFFSET: u8 = 0x28;

const ICW3_SLAVE_IRQ_MAP_TO_MASTER: u8 = 0x02;
const ICW3_MASTER_IRQ_MAP_FROM_SLAVE: u8 = 0x04;

const ICW4_80x86_MODE: u8 = 0x01;
const ICW4_AUTO_END_OF_INTERRUPT: u8 = 0x02;
const ICW4_BUFFER_SELECT: u8 = 0x04;
const ICW4_BUFFER_MODE: u8 = 0x08;
const ICW4_FULLY_NESTED_MODE: u8 = 0x10;

const OCW1_MASK_IRQ0: u8 = 0x01;
const OCW1_MASK_IRQ1: u8 = 0x02;
const OCW1_MASK_IRQ2: u8 = 0x04;
const OCW1_MASK_IRQ3: u8 = 0x08;
const OCW1_MASK_IRQ4: u8 = 0x10;
const OCW1_MASK_IRQ5: u8 = 0x20;
const OCW1_MASK_IRQ6: u8 = 0x40;
const OCW1_MASK_IRQ7: u8 = 0x80;

const OCW2_INTERRUPT_LEVEL_1: u8 = 0x01;
const OCW2_INTERRUPT_LEVEL_2: u8 = 0x02;
const OCW2_INTERRUPT_LEVEL_3: u8 = 0x04;
const OCW2_END_OF_INTERRUPT: u8 = 0x20;
const OCW2_SELECTION: u8 = 0x40;
const OCW2_ROTATION: u8 = 0x80;

const OCW3_READ_IRR: u8 = 0x00;
const OCW3_READ_ISR: u8 = 0x01;
const OCW3_ACT_ON_READ: u8 = 0x02;
const OCW3_POLL_COMMAND_ISSUED: u8 = 0x04;
const OCW3_DEFAULT: u8 = 0x08;
const OCW3_SPECIAL_MASK: u8 = 0x20;
const OCW3_ACK_ON_SPECIAL_MASK: u8 = 0x40;

pub const IRQ_PIT: u8 = 0x00;
pub const IRQ_KEYBOARD: u8 = 0x01;
pub const IRQ_CASCADE_FOR_SLAVE: u8 = 0x02;
pub const IRQ_SERIAL_PORT_2: u8 = 0x03;
pub const IRQ_SERIAL_PORT_1: u8 = 0x04;
pub const IRQ_PARALLEL_PORT_2: u8 = 0x05;
pub const IRQ_DISKETTE_DRIVE: u8 = 0x06;
pub const IRQ_PARALLEL_PORT_1: u8 = 0x07;
pub const IRQ_REAL_TIME_CLOCK: u8 = 0x08;
pub const IRQ_CGA_VERTICAL_RETRACE: u8 = 0x09;

pub const IRQ_AUXILIARY_DEVICE: u8 = 0x0C;
pub const IRQ_FLOATING_POINT_UNIT: u8 = 0x0D;
pub const IRQ_HARD_DISK_CONTROLLER: u8 = 0x0E;

pub fn sendEndOfInterrupt(irq_num: u8) void {
    return mock_framework.performAction("sendEndOfInterrupt", void, .{irq_num});
}

pub fn spuriousIrq(irq_num: u8) bool {
    return mock_framework.performAction("spuriousIrq", bool, .{irq_num});
}

pub fn setMask(irq_num: u16) void {
    return mock_framework.performAction("setMask", void, .{irq_num});
}

pub fn clearMask(irq_num: u16) void {
    return mock_framework.performAction("clearMask", void, .{irq_num});
}

pub fn remapIrq() void {
    return mock_framework.performAction("remapIrq", void);
}
