.global _start
.type _start, @function

_start:
    call kmain
halt:
	cli
	hlt
	jmp		halt