	[bits       32]

	[section	.text]
	
	[global     kmain]
	
extern	kmain

start_kernel:
	jmp		long kmain
halt:
	cli
	hlt
	jmp		halt
