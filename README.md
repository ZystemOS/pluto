Compile: zig build-exe kmain.zig -target i386-freestanding --linker-script link.ld

Run: qemu-system-i386 -kernel kmain -curses

To exit qemu: Esc + 2, type `quit`