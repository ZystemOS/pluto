export var kernel_stack: [16 * 1024]u8 align(16) linksection(".bss.stack") = undefined;

extern fn kmain() void;
extern var KERNEL_STACK_END: *usize;

export fn _start() linksection(".text.boot") callconv(.Naked) noreturn {
    // The 32bit address to the DTB is in x0
    // Setup the stack
    asm volatile ("mov sp, %[stack_end]"
        :
        : [stack_end] "r" (@ptrCast([*]u8, &KERNEL_STACK_END))
    );

    //kmain(0);
    while (true) {}
}
