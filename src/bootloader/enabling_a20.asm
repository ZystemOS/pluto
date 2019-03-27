; Purpose:	To check the status of the a20 line in a completely self-contained state-preserving way.
;			The function can be modified as necessary by removing pushes at the beginning and their
;			respective pop's at the end if complete self-containment is not required.
;
; Returns:	0 in AX if the a20 line is disabled (memory wraps around)
;			1 in AX if the a20 line is enabled (memory does not wrap around)
test_a20:
	pushf
	push	ds
	push	es
	push	di
	push	si
	
	cli
	
	xor		ax, ax
	mov		es, ax
	
	mov		ax, 0xFFFF
	mov		ds, ax
	
	mov		di, 0x0500
	mov		si, 0x0510
	
	mov		al, byte [es:di]
	push	ax
	
	mov		al, byte [ds:si]
	push	ax
	
	mov		byte [es:di], 0x00
	mov		byte [ds:si], 0xFF
	
	cmp		byte [es:di], 0xFF
	
	pop		ax
	mov		byte [ds:si], al
	
	pop		ax
	mov		byte [es:di], al
	
	mov		ax, 0
	je		.a20_enabled
	
	mov		ax, 1
	
.a20_enabled:
	pop		si
	pop		di
	pop		es
	pop		ds
	popf
	ret

%macro m_enable_a20_via_bios 0						; Try to enable the a20 line using the BIOS, need to test after this
	pusha
	mov		ax, 0x2403								; Test if BIOS supports enabling a20 line
	int		0x15
	jb		short .m_enable_a20_via_bios_done
	cmp		ah, 0
	jnz		short .m_enable_a20_via_bios_done
	
	mov		ax, 0x2402								; Test the status of the a20 line
	int		0x15
	jb		short .m_enable_a20_via_bios_done
	cmp		ah, 0
	jnz		short .m_enable_a20_via_bios_done
	cmp		al, 1
	jz		short .m_enable_a20_via_bios_done		; Already enabled
	
	mov		ax, 0x2401								; Enable the a20 line
	int		0x15
.m_enable_a20_via_bios_done:
	popa
%endmacro

; Can enable the a20 line by using the keyboard
a20_wait_command:									; But need to check if the keyboard is ready to receive commands
	in		al, 0x64
	test	al, 0x02
	jnz		a20_wait_command
	ret

a20_wait_data:										;  But need to check if the keyboard is ready to receive data
	in		al, 0x64
	test	al, 0x01
	jz		a20_wait_data
	ret

%macro m_enable_a20_via_keyboard 0
	cli
	
	call a20_wait_command
	mov		al, 0xAD								; Disable keyboard
	out		0x64, al
	
	call a20_wait_command
	mov		al, 0xD0								; Send command 0xd0 (read from input)
	out		0x64, al
	
	call a20_wait_data
	in		al, 0x60								; Read input
	push	eax										; Save input
	
	call a20_wait_command
	mov		al, 0xD1								; Send command 0xd1 (Write to output)
	out		0x64, al
	
	call a20_wait_command
	pop		eax										; Write input back
	or		al, 2
	out		0x60, al
	
	call a20_wait_command
	mov		al, 0xAE								; Enable keyboard
	out		0x64, al
	
	call a20_wait_command
	sti
%endmacro

%macro m_enable_a20_fast 0
	in		al, 0x92
	test	al, 0x02
	jnz		short .m_enable_a20_fast_done
	
	or		al, 0x02
	and		al, 0xFE
	out		0x92, al
.m_enable_a20_fast_done:
%endmacro

%macro m_enable_a20 0
	call	test_a20
	cmp		ax, 0
	jne		.a20_enabled
	
	m_enable_a20_via_keyboard
	
	call	test_a20
	cmp		ax, 0
	jne		.a20_enabled
	
	m_enable_a20_via_bios
	
	call	test_a20
	cmp		ax, 0
	jne		.a20_enabled
	
	m_enable_a20_fast
	
	call	test_a20
	cmp		ax, 0
	jne		.a20_enabled
	
.a20_enabled_failed:
	m_write_line a20_error
	m_reboot
	
.a20_enabled:
%endmacro
