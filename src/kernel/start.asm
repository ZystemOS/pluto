	[bits		32]
	[section	.text]

	[extern		kernel_main]
start:
	call	kernel_main
halt:
	cli
	hlt
	jmp		halt
