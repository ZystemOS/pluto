const arch = @import("arch.zig");
const Cpu = arch.Cpu;
const interrupts = @import("interrupts.zig");
const rpi = @import("rpi.zig");

const number_of_cores = 4;
const per_core_stack_size = 16 * 1024;
export var kernel_stack: [number_of_cores * per_core_stack_size]u8 align(16) linksection(".bss.stack") = undefined;

extern fn kmain(payload: *const rpi.RaspberryPiBoard) void;
extern var KERNEL_STACK_END: *usize;

export fn _start() linksection(".text.boot") callconv(.Naked) noreturn {
    // Give each of four cores one-fourth of the reserved stack space
    asm volatile (
        \\ mrs x0, mpidr_el1
        \\ and x0, x0, #0x3
        \\ add x0, x0, #1     // core number + 1 therefore 1..4
        \\ mov x1, #16 * 1024 // per_core_stack_size
        \\ mul x0, x0, x1
        \\ ldr x1, =kernel_stack
        \\ add x0, x0, x1
        \\ mov sp, x0
        :
        :
        : "x0", "x1"
    );

    start(); // must start a proper zig function to get x29 (frame pointer) initialized!
}

fn start() noreturn {
    // Halt all cores other than core 0, until the kernel has multicore support
    if (Cpu.mpidr.el(1).read() & 0x3 != 0) {
        while (true) {
            Cpu.wfe();
        }
    }

    // Give all exception levels the same vector table
    Cpu.vbar.el(1).write(@ptrToInt(&interrupts.exception_table));
    Cpu.vbar.el(2).write(@ptrToInt(&interrupts.exception_table));
    Cpu.vbar.el(3).write(@ptrToInt(&interrupts.exception_table));

    interrupts.exception_handler_depth = 0;

    arch.enableFlatMmu();

    board = detectBoard();
    arch.initMmioAddress(&board);

    kmain(&board);
    while (true) {}
}

var board: rpi.RaspberryPiBoard = undefined;

fn detectBoard() rpi.RaspberryPiBoard {
    const part_number = @truncate(u12, Cpu.midr.el(1).read() >> 4);
    return rpi.RaspberryPiBoard.fromPartNumber(part_number) orelse @panic("Unrecognised part number");
}
