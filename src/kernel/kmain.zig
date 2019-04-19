//
// kmain
// Zig version:
// Author: DrDeano
// Date: 2019-03-30
//
const builtin = @import("builtin");

const MultiBoot = packed struct {
    magic: i32,
    flags: i32,
    checksum: i32,
};

const ALIGN = 1 << 0;
const MEMINFO = 1 << 1;
const MAGIC = 0x1BADB002;
const FLAGS = ALIGN | MEMINFO;

export var multiboot align(4) linksection(".rodata.boot") = MultiBoot{
    .magic = MAGIC,
    .flags = FLAGS,
    .checksum = -(MAGIC + FLAGS),
};

const KERNEL_ADDR_OFFSET = 0xC0000000;
const KERNEL_PAGE_NUMBER = KERNEL_ADDR_OFFSET >> 22;
// The number of pages occupied by the kernel, will need to be increased as we add a heap etc.
const KERNEL_NUM_PAGES = 1;

// The initial page directory used for booting into the higher half. Should be overwritten later
export var boot_page_directory: [1024]u32 align(4096) linksection(".rodata.boot") = init: {
    // Temp value
    var dir: [1024]u32 = undefined;

    // Page for 0 -> 4 MiB. Gets unmapped later
    dir[0] = 0x00000083;

    var i = 0;
    var idx = 1;

    // Fill preceding pages with zeroes. May not be unecessary but incurs no runtime cost
    while (i < KERNEL_PAGE_NUMBER - 1) {
        dir[idx] = 0;
        i += 1;
        idx += 1;
    }

    // Map the kernel's higher half pages increasing by 4 MiB every time
    i = 0;
    while (i < KERNEL_NUM_PAGES) {
        dir[idx] = 0x00000083 | (i << 22);
        i += 1;
        idx += 1;
    }
    // Increase max number of branches done by comptime evaluator
    @setEvalBranchQuota(1024);
    // Fill suceeding pages with zeroes. May not be unecessary but incurs no runtime cost
    i = 0;
    while (i < 1024 - KERNEL_PAGE_NUMBER - KERNEL_NUM_PAGES) {
        dir[idx] = 0;
        i += 1;
        idx += 1;
    }
    break :init dir;
};

export var kernel_stack: [16 * 1024]u8 align(16) linksection(".bss.stack") = undefined;

export nakedcc fn _start() align(16) linksection(".text.boot") noreturn {
    // Seth the page directory to the boot directory
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
        \\mov %%esp, %%ebp
    );
    kmain();
    while (true) {}
}

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
    @setCold(true);
    terminal.write("KERNEL PANIC: ");
    terminal.write(msg);
    while (true) {}
}

fn kmain() void {
    terminal.initialize();
    terminal.write("Hello, kernel World!");
}

// Hardware text mode color constants
const VGA_COLOUR = enum(u8) {
    VGA_COLOUR_BLACK,
    VGA_COLOUR_BLUE,
    VGA_COLOUR_GREEN,
    VGA_COLOUR_CYAN,
    VGA_COLOUR_RED,
    VGA_COLOUR_MAGENTA,
    VGA_COLOUR_BROWN,
    VGA_COLOUR_LIGHT_GREY,
    VGA_COLOUR_DARK_GREY,
    VGA_COLOUR_LIGHT_BLUE,
    VGA_COLOUR_LIGHT_GREEN,
    VGA_COLOUR_LIGHT_CYAN,
    VGA_COLOUR_LIGHT_RED,
    VGA_COLOUR_LIGHT_MAGENTA,
    VGA_COLOUR_LIGHT_BROWN,
    VGA_COLOUR_WHITE,
};

fn vga_entry_colour(fg: VGA_COLOUR, bg: VGA_COLOUR) u8 {
    return @enumToInt(fg) | (@enumToInt(bg) << 4);
}

fn vga_entry(uc: u8, colour: u8) u16 {
    return u16(uc) | (u16(colour) << 8);
}

const VGA_WIDTH = 80;
const VGA_HEIGHT = 25;

const terminal = struct {
    var row = usize(0);
    var column = usize(0);
    var colour = vga_entry_colour(VGA_COLOUR.VGA_COLOUR_LIGHT_GREY, VGA_COLOUR.VGA_COLOUR_BLACK);

    const buffer = @intToPtr([*]volatile u16, 0xC00B8000);

    fn initialize() void {
        var y = usize(0);
        while (y < VGA_HEIGHT) : (y += 1) {
            var x = usize(0);
            while (x < VGA_WIDTH) : (x += 1) {
                putCharAt(' ', colour, x, y);
            }
        }
    }

    fn setColour(new_colour: u8) void {
        colour = new_colour;
    }

    fn putCharAt(c: u8, new_colour: u8, x: usize, y: usize) void {
        const index = y * VGA_WIDTH + x;
        buffer[index] = vga_entry(c, new_colour);
    }

    fn putChar(c: u8) void {
        putCharAt(c, colour, column, row);
        column += 1;
        if (column == VGA_WIDTH) {
            column = 0;
            row += 1;
            if (row == VGA_HEIGHT)
                row = 0;
        }
    }

    fn write(data: []const u8) void {
        for (data) |c|
            putChar(c);
    }
};
