ENTRY(_start)

SECTIONS {
	. = 0;
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
