const constants = @import("constants");

/// The multiboot header
const MultiBoot = packed struct {
    magic: i32,
    flags: i32,
    checksum: i32,
};

const ALIGN = 1 << 0;
const MEMINFO = 1 << 1;
const MAGIC = 0x1BADB002;
const FLAGS = ALIGN | MEMINFO;

const KERNEL_PAGE_NUMBER = constants.KERNEL_ADDR_OFFSET >> 22;
// The number of pages occupied by the kernel, will need to be increased as we add a heap etc.
const KERNEL_NUM_PAGES = 1;

export var multiboot align(4) linksection(".rodata.boot") = MultiBoot{
    .magic = MAGIC,
    .flags = FLAGS,
    .checksum = -(MAGIC + FLAGS),
};

// The initial page directory used for booting into the higher half. Should be overwritten later
export var boot_page_directory: [1024]u32 align(4096) linksection(".rodata.boot") = init: {
    // Increase max number of branches done by comptime evaluator
    @setEvalBranchQuota(1024);
    // Temp value
    var dir: [1024]u32 = undefined;

    // Page for 0 -> 4 MiB. Gets unmapped later
    dir[0] = 0x00000083;

    var i = 0;
    var idx = 1;

    // Fill preceding pages with zeroes. May be unnecessary but incurs no runtime cost
    while (i < KERNEL_PAGE_NUMBER - 1) : ({
        i += 1;
        idx += 1;
    }) {
        dir[idx] = 0;
    }

    // Map the kernel's higher half pages increasing by 4 MiB every time
    i = 0;
    while (i < KERNEL_NUM_PAGES) : ({
        i += 1;
        idx += 1;
    }) {
        dir[idx] = 0x00000083 | (i << 22);
    }
    // Fill succeeding pages with zeroes. May be unnecessary but incurs no runtime cost
    i = 0;
    while (i < 1024 - KERNEL_PAGE_NUMBER - KERNEL_NUM_PAGES) : ({
        i += 1;
        idx += 1;
    }) {
        dir[idx] = 0;
    }
    break :init dir;
};

export var kernel_stack: [16 * 1024]u8 align(16) linksection(".bss.stack") = undefined;

extern fn kmain() void;

export nakedcc fn _start() align(16) linksection(".text.boot") noreturn {
    // Set the page directory to the boot directory
    asm volatile (
        \\.extern boot_page_directory
        \\mov $boot_page_directory, %%ecx
        \\mov %%ecx, %%cr3
    );

    // Enable 4 MiB pages
    asm volatile (
        \\mov %%cr4, %%ecx
        \\or $0x00000010, %%ecx
        \\mov %%ecx, %%cr4
    );

    // Enable paging
    asm volatile (
        \\mov %%cr0, %%ecx
        \\or $0x80000000, %%ecx
        \\mov %%ecx, %%cr0
    );
    asm volatile ("jmp start_higher_half");
    while (true) {}
}

export nakedcc fn start_higher_half() noreturn {
    // Invalidate the page for the first 4MiB as it's no longer needed
    asm volatile ("invlpg (0)");

    // Setup the stack
    asm volatile (
        \\.extern KERNEL_STACK_END
        \\mov $KERNEL_STACK_END, %%esp
        \\xor %%ebp, %%ebp
    );

    // Push the bootloader magic number and multiboot header address with virtual offset
    asm volatile (
        \\.extern KERNEL_ADDR_OFFSET
        \\push %%eax
        \\add $KERNEL_ADDR_OFFSET, %%ebx
        \\push %%ebx
    );
    kmain();
    while (true) {}
}
