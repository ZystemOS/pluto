; The reboot macro
%macro m_reboot_with_msg 1
    m_write_line %1
    call    reboot
%endmacro

; m_write_line str_to_write
%macro m_write_line 1
    lea     si, [%1]
    call    print_string_with_new_line
%endmacro

%macro m_reset_disk 0
    mov     dl, byte [Logical_drive_number]     ; The drive to reset
    xor     ah, ah                              ; The sub function to reset the floppy (0)
    int     0x13                                ; Call BIOS interrupt 13h
    jc      boot_error                          ; If there was an error resetting the floppy, then the carry bit will be set
                                                ; If so, jump to failure function and reboot
%endmacro

; Fine a file on the disk
; m_find_file filename, load_segment
%macro m_find_file 2
    mov     ax, %2
    mov     es, ax
    ; Calculate the number of sectors for the root directory
    ; root_sectors = (root_size * 32) / 512
    mov     ax, 32
    xor     dx, dx                          ; Must be 0 initially for the multiplication
    mul     word [Root_directory_size]
    div     word [Bytes_per_sector]
    mov     cx, ax                          ; The number of root entries to read in CX for the loop
    mov     word [root_sectors], ax         ; Save this value
    
    ; Calculate the start of the root directory
    ; root_start = (FAT tables) * (sectors per FAT) + (reserved sectors) + (hidden sectors)
    xor     ax, ax
    mov     al, byte [FAT_tables]
    mul     word [Sectors_per_FAT]
    add     ax, word [Hidden_sectors]       ; Add the top half of hidden sectors
    adc     ax, word [Hidden_sectors + 2]   ; Add the bottom half with carry of hidden sectors
    add     ax, word [Reserved_sectors]
    mov     word [root_start], ax           ; Save this value
    
.read_next_sector:                          ; Read a sector from the root directory
                                            ; If the reading fails, will reboot
                                            ; CX is a loop counter for how many sector to read until failure
    push    cx                              ; Save the number of sector for the root directory on the stack
    push    ax                              ; Save the start of the root directory on the stack
    xor     bx, bx
    call    read_sector                     ; Read the root directory stored in ax
    
.check_entry:                               ; Check that the loaded sector contain the file we want
    mov     cx, 11                          ; Directory entry's are 11 bytes long (file name + file extension = 8 + 3)
    mov     di, bx                          ; ES:DI is the directory entry address
    lea     si, [%1]                        ; Load the file name the we are checking for into the SI register (DS:SI)
    repz    cmpsb                           ; Compare the filename in SI to memory (for 11 bytes)
    je      short .found_file               ; If the string matches, the found file
                                            ; Else try the next entry
    add     bx, 32
    cmp     bx, word [Bytes_per_sector]     ; Have we move out of the sector
    jne     short .check_entry              ; If not, then try the next entry
    
    pop     ax
    inc     ax                              ; Increment to the next logical block address 
    pop     cx
    loopnz  .read_next_sector               ; Decrement CX counter and if not 0 then read the next sector
    jmp     boot_error                      ; Else if 0, then the file wasn't found so reboot
.found_file:                                ; The stage 2 bootloader file has been found
    mov     ax, word [es:(bx + 0x1A)]       ; The directory entry stores the first cluster number of the file
                                            ; at byte 26 (0x1A). BX is pointing to the address of the start of
                                            ; the directory entry, so go from there
    mov     word [file_start], ax           ; Save the start of the stage 2 bootloader file
    
    pop     ax
    pop     cx
%endmacro

; Read a FAT into memory
; m_read_fat FAT_segment
%macro m_read_fat 1
    mov     ax, %1                          ; Load the memory location for the FAT
    mov     es, ax                          ; The FAT will be loaded into the extra segment
    ; Calculate the offset of FAT12
    mov     ax, word [Reserved_sectors]     ; Add the reserved sectors
    add     ax, word [Hidden_sectors]       ; Add the hidden sectors
    adc     ax, word [Hidden_sectors + 2]
    ;Read all FAT sectors into memory
    mov     cx, word [Sectors_per_FAT]      ; Read the number of sectors per FAT
    xor     bx, bx                          ; Set the start offset to be 0x00
.read_next_fat_sector:
    push    cx                              ; Save the loop counter
    push    ax                              ; Save the start of the FAT
    call    read_sector                     ; Read the FAT sector
    pop     ax
    pop     cx
    inc     ax                              ; Increment the logical block address for the next sector
    add     bx, word [Bytes_per_sector]     ; Increment by the size of the sector sector
    loopnz  .read_next_fat_sector           ; Repeatedly read each FAT into memory (CX of them)
%endmacro

; Read a file into memory
; m_read_file load_segment FAT_segment
; AX    - Is used for the logical block address when reading the sector from the floppy using the FAT table
;       - The is used for calculating the next FAT entry to read
; ES:BX - Is used for the buffer location which the sectors will be read into
; CX    - Is used for calculating the next FAT entry
;       - Then storing the next FAT entry
; DX    - Is used for testing whether to mask the upper bits or shift out the 4 bits
; DS:SI - Is used for the location for the FAT table and SI to index into the FAT table
%macro m_read_file 2
    ; The root directory will be loaded in a higher segment.
    ; Set ES to this segment.
    ; Here AX is used to set up the extra segment to point to the load segment where the 2nd stage is loaded
    mov     ax, %1                          ; Set up the memory segment that will receive the file
    mov     es, ax
    xor     bx, bx                          ; Set the start offset to be 0x00
    mov     cx, word [file_start]           ; Load the start of the file
.read_next_file_sector:
    ; Locate the sector to read
    mov     ax, cx                          ; Sector to read is equal to the current FAT entry
    add     ax, word [root_start]           ; Add the start location of the root directory
    add     ax, word [root_sectors]         ; Add the size of the root directory
    sub     ax, 2                           ; minus 2?

    ; Read the sector
    push    cx
    call    read_sector
    pop     cx
    add     bx, word [Bytes_per_sector]
    
    ; Get the next sector to read
    push    ds                              ; Save the previous data segment value
    mov     dx, %2                          ; Make DS:SI (the data segment) point to the FAT
    mov     ds, dx
    
    push    bx                              ; Save BX as is used for multiply and divide and contains the load location
    
    mov     ax, cx                          ; Get the start of the FAT entry
    xor     dx, dx                          ; Set DX to 0 for the multiply and divide
    mov     bx, 3                           ; For multiply by 3      -|
    mul     bx                              ;                         |
    mov     bx, 2                           ; For divide by 2         |- This is for AX * 1.5
    div     bx                              ; AX - (AX * 3) / 2      -|
                                            ; DX - (AX * 3) mod 2    - This to check which 4 bits of a byte is needed
    mov     si, ax                          ; Set the location for the next FAT entry at DS:SI
    
    pop     bx                              ; Restore BX for the buffer location

    mov     cx, word [ds:si]                ; Read the FAT entry
    
    or      dx, dx                          ; If is even, then drop last 4 bits of word
                                            ; Else is odd, shift the first 4 bits of word

    jnz     .read_next_cluster_old          ; If is even
    and     cx, 0x0FFF                      ; Then mask the upper 4 bits
    jmp     .read_next_file_cluster_done
.read_next_cluster_old:                     ; If odd
    shr     cx, 4                           ; Shift the 4 bits to the right 
.read_next_file_cluster_done:
    pop     ds                              ; Restore DS segment to normal
    cmp     cx, 0xFF8                       ; If FAT entry is 0x0FF8, then is the end of file (for FAT12)
    jl      .read_next_file_sector          ; If not end of file, read the next sector
%endmacro

; Need to copy the boot sector from the first stage bootloader as contains information thats might have changed
; during the first stage
%macro m_copy_boot_sector 0
    push    ds                              ; Need to set DS:SI to 0x0000:0x7C03
    xor     ax, ax
    mov     ds, ax
    mov     si, boot_sector_location
    mov     di, boot_sector                 ; Set ES:DI to location of second stage boot sector
    mov     cx, 34                          ; The fist 34 bytes to copy as the rest isn't changed
    rep     movsb
    pop     ds
%endmacro

; Enable protected mode
%macro m_enable_protected 0
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax
%endmacro

%macro m_save_cursor 0
    mov     word [boot_parameters.signature], SIGNATURE
    
    mov     ah, 0x03
    xor     bh, bh
    int     0x10
    
    mov     byte [boot_parameters.cursor_pos_x], dl
    mov     byte [boot_parameters.cursor_pos_y], dh
%endmacro

; Set up segments to point to the data GDT table (0x10)
%macro m_set_up_segments 0
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     esp, kernel_stack
    mov     ebp, esp
%endmacro

; Parameter: the memory map table memory segment to be stores at
%macro m_get_memory_size 0
    xor     eax, eax
    xor     ebx, ebx
    
    m_bios_get_memory_size_E801
    
    mov     word [boot_parameters.memory_lower], ax
    mov     word [boot_parameters.memory_upper], bx
    
    push    es
    push    di
    
    xor     ax, ax
    mov     ax, memory_map_segment    ; Set up the memory segment for where the memory map table will be loaded into
    mov     es, ax
    
    xor     di, di
    
    m_bios_get_memory_map
    
    pop     di
    pop     es
    
    mov     word [boot_parameters.memory_map_length], si
    mov     dword [boot_parameters.memory_map_address], memory_map_location
%endmacro
