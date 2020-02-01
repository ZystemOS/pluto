ENTRY(_start)

KERNEL_ADDR_OFFSET = 0xC0000000;
KERNEL_VADDR_START = 0xC0100000;

SECTIONS {
	. = 1M;
	KERNEL_PHYSADDR_START = .;

	.rodata.boot : {
		*(.rodata.boot)
	}

	.text.boot : {
		*(.text.boot)
	}

	. += KERNEL_ADDR_OFFSET;

	.text ALIGN(4K) : AT (ADDR(.text) - KERNEL_ADDR_OFFSET) {
		*(.text)
	}

	.rodata ALIGN(4K) : AT (ADDR(.rodata) - KERNEL_ADDR_OFFSET) {
		*(.rodata)
	}

	.data ALIGN(4K) : AT (ADDR(.data) - KERNEL_ADDR_OFFSET) {
		*(.data)
	}

	.bss ALIGN(4K) : AT (ADDR(.bss) - KERNEL_ADDR_OFFSET) {
		*(COMMON)
		*(.bss)
	}

	.bss.stack ALIGN(4K) : AT (ADDR(.bss.stack) - KERNEL_ADDR_OFFSET) {
		KEEP(*(.bss.stack))
        KERNEL_STACK_END = .;
    }

	KERNEL_VADDR_END = .;
	KERNEL_PHYSADDR_END = . - KERNEL_ADDR_OFFSET;

}
