ENTRY(_start)

SECTIONS {
	/* The binary is loaded at 0x80000 for aarch64 and 0x8000 for arm */
	. = 0x80000;
	KERNEL_PHYSADDR_START = .;

	.text ALIGN(4K) : {
		KEEP(*(.text.boot))
		*(.text)
	}

	.rodata ALIGN(4K) : {
		*(.rodata)
	}

	.data ALIGN(4K) : {
		*(.data)
	}

	.bss ALIGN(4K) : {
		*(.bss)
	}

	.bss.stack ALIGN(4K) : {
		KEEP(*(.bss.stack))
		KERNEL_STACK_END = .;
	}
	KERNEL_PHYSADDR_END = .;
}
