ENTRY(entry)

SECTIONS {

	.text ALIGN(4K) : {
		*(.text)
	}

	.data ALIGN(4K) : {
		*(.data)
	}

}
