; Print a null terminated string to the screen
; DS:SI is the location of the string
; Input:
;	SI - pointer to the string to be printed in register SI
print_string_with_new_line:
	pusha				; Push all registers onto the stack
	mov		ah, 0x0E	; Specify the teletype output function
	xor		bx, bx
.loop:
	lodsb				; Load byte at address SI into AL and increment SI
	cmp		al, 0		; If it the end of the null-terminated string
	je		.done		; Then exit
	int		0x10		; Else print the character in AL as an interrupt into the BIOS
	jmp		short .loop ; Repeat for next character
.done:
	; Print the line feed and carriage return
	mov		al, 0x0A	; Teletype print sub function(0x0E), Line feed (0x0A)
	int		0x10
	mov		al, 0x0D	; Carriage return
	int		0x10
	popa				; Pop the register of the stack
	ret					; And return to caller

; Reboot the computer if there was an error
reboot:
	m_write_line reboot_msg
	
	xor		ah, ah					; Sub function for reading a character
	int		0x16	 				; Wait for key press
	int		0x19	 				; Warm reboot
	
	cli		 	 				; If failed to reboot, halt
	hlt								; Halt
	
; Read a sector from the disk
; es:bx is the location of the buffer that the data is read into
; As reads often fail, it will try 4 times to read from the disk. The counter is stored in CX.
; With the data buffer at ES:BX
; Input:
;	AX	- The logical block address (LBA)
;	ES:BX - The buffer location which the sector will be read into
read_sector:
	xor		cx, cx					; Set the counter to 0
.read:
	push	ax						; Save the logical block address
	push	cx						; Save the counter
	
	; Convert the logical block address into the head-cylinder/track-sector values
	
; The conversions are:
; (1) Sector	= (LBA mod SectorsPerTrack) + 1
; (2) Cylinder	= (LBA / SectorsPerTrack) / NumHeads
; (3) Head		= (LBA / SectorsPerTrack) mod NumHeads
;
; Input:
;	AX - the logical block address
; Output: These are used for the 0x13 BIOS interrupt to read from the disk along with ES:BX and ax
;	CH - Lower 8 bits of cylinder
;	CL - Upper 2 bits of cylinder and 6 bits for the sector
;	DH - The head number
;	DL - The drive number/ID
.lba_to_hcs:
	push	bx							; Save the buffer location
	
	;mov		bx, word [Sectors_per_track]	; Get the sectors per track
	xor		dx, dx						; Set DX to 0x0 (part of operand for DIV instruction and needs to be 0x00)
	div		word [Sectors_per_track]	; Divide (DX:AX / Sectors_per_track)
										; Quotient (AX)		- LBA / SectorsPerTrack
										; Remainder (DX)	- LBA mod SectorsPerTrack
									
	inc		dx							; (1) Sector = (LBA mod SectorsPerTrack) + 1
	mov		cl, dl						; Store sector in cl as defined for the output and for the 0x13 BIOS interrupt
	
	;mov		bx, word [Head_count]	; Get the number of heads
	xor		dx, dx
	div		word [Head_count]			; Quotient (AX)		- Cylinder	= (LBA / SectorsPerTrack) / NumHeads
										; Remainder (DX)	- Head		= (LBA / SectorsPerTrack) mod NumHeads
	
	mov		ch, al						; Store cylinder in ch as defined for the output and for the 0x13 BIOS interrupt
	mov		dh, dl						; Store head in DH as defined for the output and for the 0x13 BIOS interrupt
	
	mov		dl, byte [Logical_drive_number]	; Store drive number in DL as defined for the output and for the 0x13 BIOS interrupt
	
	pop		bx							; Restore the buffer location
	
	; Using the values above, read off the drive
	
	mov		ax, 0x0201				; Sub function 2 to read from the disk, Read 1 (0x01) sector
	int		0x13					; Call BIOS interrupt 13h
	jc		short .read_fail		; If fails to read (carry bit set)

	pop		cx
	pop		ax						; Restore the logical block address
	ret								; If read successful, then return to caller
.read_fail:							; If failed to read, try again, if tried 4 times, the reboot
	pop		cx						; Restore the counter
	inc		cx						; Increment the counter
	cmp		cx, 4					; Compare if counter is equal to 4
	je		boot_error				; If equal, then error reading 4 times so reboot
	xor		ah, ah					; Reset the disk to try again
	int		0x13
	
	pop		ax						; Restore the logical block address
	jmp		.read					; Try to read again
