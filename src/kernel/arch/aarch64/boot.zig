const rpi = @import("rpi.zig");
export var kernel_stack: [16 * 1024]u8 align(16) linksection(".bss.stack") = undefined;

extern fn kmain(payload: *const rpi.RaspberryPiBoard) void;
extern var KERNEL_STACK_END: *usize;

export fn _start() linksection(".text.boot") callconv(.Naked) noreturn {
    // The 32bit address to the DTB is in the lower bits of x0
    // Setup the stack
    asm volatile ("mov sp, %[stack_end]"
        :
        : [stack_end] "r" (@ptrCast([*]u8, &KERNEL_STACK_END))
    );
    // Halt all cores other than the primary core, until the kernel has multicore support
    const core_id = asm ("mrs %[res], mpidr_el1"
        : [res] "=r" (-> usize)
    ) & 3;
    if (core_id != 0) {
        while (true) {
            asm volatile ("wfe");
        }
    }

    // The rpi puts the board part number in midr_el1
    const board = detectBoard();

    kmain(&board);
    while (true) {}
}

fn detectBoard() rpi.RaspberryPiBoard {
    const part_number = @truncate(u12, asm ("mrs %[res], midr_el1"
        : [res] "=r" (-> usize)
    ) >> 4);
    return rpi.RaspberryPiBoard.fromPartNumber(part_number) orelse @panic("Unrecognised part number");
}
