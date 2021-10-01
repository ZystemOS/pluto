ENTRY(_start)

OUTPUT_FORMAT(elf64-x86-64)

KERNEL_PHYSADDR_START = 1M;
KERNEL_ADDR_OFFSET = 0xFFFFFFFF80000000;
KERNEL_VADDR_START = KERNEL_ADDR_OFFSET + KERNEL_PHYSADDR_START;

SECTIONS {
    . = KERNEL_VADDR_START;

    .stivale2hdr ALIGN(4K) : {
        KEEP(*(.stivale2hdr))
    }

    .text.boot ALIGN(4K) : {
        *(.text.boot)
    }

    .text ALIGN(4K) : {
        *(.text)
        *(.text*)
    }

    .rodata ALIGN(4K) : {
        *(.rodata)
        *(.rodata*)
    }

    .data ALIGN(4K) : {
        *(.data)
        *(.data*)
    }

    .bss ALIGN(4K) : {
        KEEP(*(.bss))
        *(COMMON)
        KEEP(*(.bss*))
    }

    .stack ALIGN(4K) : {
        KERNEL_STACK_START = .;
        *(.stack)
        *(.stack*)
        KERNEL_STACK_END = .;
    }

    KERNEL_VADDR_END = .;
    KERNEL_PHYSADDR_END = KERNEL_VADDR_END - KERNEL_ADDR_OFFSET;
}
