	[bits	32]
	
%define		VIDMEM		0xB8000		; Video memory mapped
%define		COLUMNS		80			; Width and height of screen (80x25)
%define		ROWS		25
%define		CHAR_ATTRIB	0x02		; Character attribute
	
; Prints a character
; Input:
;	BL - The character to print
print_char_32:
	pusha
	mov		edi, VIDMEM				; Let EDI point to the start of video memory
	xor		eax, eax				; Clear EAX
	
	mov		ecx, COLUMNS
	mov		al, byte [boot_parameters.cursor_pos_y]	; Get the y position
	mul		ecx						; Multiply by the number of columns (EAX = y * COLUMNS)
	
	xor		ecx, ecx
	mov		cl, byte [boot_parameters.cursor_pos_x]	; Get the x position
	add		eax, ecx				; Add the x position to (y * COLUMS)
	shl		eax, 1					; Multiply by 2 as 2 bytes per character
	
	add		edi, eax				; Add the offset to the video memory address
	
	cmp		bl, 0x0A				; Is it a new line
	je		short .new_line
	
	mov		dl, bl					; Get the character to print
	mov		dh, CHAR_ATTRIB			; Add the character attribute
	mov		word [edi], dx			; Write to the video memory
	
	inc		byte [boot_parameters.cursor_pos_x]		; Increment the x position
	jmp		short .print_done
	
.new_line:
	mov		byte [boot_parameters.cursor_pos_x], 0	; Set cursor to beginning of line
	inc		byte [boot_parameters.cursor_pos_y]		; Increment new line
	
.print_done:
	popa
	ret

; Print a null terminated string to the screen
; Input:
;	ESI - Pointer to the string to print
print_string_32:
	pusha

.print_loop:
	mov		bl, byte [esi]		; Get the character to print
	cmp		bl, 0				; Is it null
	je		short .print_end			; Then finish
	
	call	print_char_32		; Print the character
	
	inc		esi					; Increment to next character
	jmp		short .print_loop
	
.print_end:
	mov		bh, byte [boot_parameters.cursor_pos_y]
	mov		bl, byte [boot_parameters.cursor_pos_x]
	call	update_cursor		; Update the cursor
	
	popa
	ret

; Update the cursors new position
; Input:
;	BH - y position
;	BL - x position
update_cursor:
	pusha
	
	xor		eax, eax
	mov		ecx, COLUMNS
	mov		al, bh
	mul		ecx
	add		al, bl
	mov		ebx, eax
	
	mov		al, 0x0f
	mov		dx, 0x03D4
	out		dx, al

	mov		al, bl
	mov		dx, 0x03D5
	out		dx, al
	
	xor		eax, eax

	mov		al, 0x0e
	mov		dx, 0x03D4
	out		dx, al

	mov		al, bh
	mov		dx, 0x03D5
	out		dx, al

	popa
	ret
