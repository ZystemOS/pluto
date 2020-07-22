const rpi = @import("rpi.zig");
const arch = @import("arch.zig");
const interrupts = @import("interrupts.zig");

export var kernel_stack: [16 * 1024]u8 align(16) linksection(".bss.stack") = undefined;

extern fn kmain(payload: *const rpi.RaspberryPiBoard) void;
extern var KERNEL_STACK_END: *usize;

export fn _start() linksection(".text.boot") callconv(.Naked) noreturn {
    // Halt all cores other than the primary core, until the kernel has multicore support
    asm volatile (
        \\ mrs x0, mpidr_el1
        \\ mov x1, #3
        \\ ands x0, x0, x1
        \\ beq cpu0
        \\hang:
        \\ wfe
        \\ b hang
        \\cpu0:
    );

    // Setup the stack
    asm volatile (
        \\mov sp, %[stack_end]
        :
        : [stack_end] "r" (@ptrCast([*]u8, &KERNEL_STACK_END))
    );

    // Setup the exception table
    asm volatile (
        \\ msr vbar_el1, %[table_addr]
        \\ msr vbar_el2, %[table_addr]
        \\ mrs x0, CurrentEL
        \\ lsr x0, x0, 2
        \\ and x0, x0, #3
        \\ cmp x0, #3
        \\ bne not_el3
        \\ msr vbar_el3, %[table_addr]
        \\not_el3:
        :
        : [table_addr] "r" (@ptrToInt(&interrupts.exception_table))
    );

    // The rpi puts the board part number in midr_el1
    const board = rpi.RaspberryPiBoard.RaspberryPi3; // detectBoard();

    kmain(&board);
    while (true) {}
}

fn detectBoard() rpi.RaspberryPiBoard {
    const part_number = @truncate(u12, asm ("mrs %[res], midr_el1"
        : [res] "=r" (-> usize)
    ) >> 4);
    return rpi.RaspberryPiBoard.fromPartNumber(part_number) orelse @panic("Unrecognised part number");
}
