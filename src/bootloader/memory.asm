    [bits    16]

; Get the number of KB of conventional memory up to 64KB.
; Output:
;   AX - The number of KB of conventional memory or -1 if error.
%macro m_bios_get_conventional_memory_size 0
    int     0x12
    jc      short .error_1
    test    ax, ax             ; If size=0
    je      short .error_1
    cmp     ah, 0x86           ; Unsupported function
    je      short .error_1
    cmp     ah, 0x80           ; Invalid command
    je      short .error_1
    ret
.error_1:
    mov     ax, -1
%endmacro

; Get the number of contiguous KB starting at 1MB of extended memory up to 64MB.
; Output:
;   AX - The number of contiguous KB starting at 1MB of extended memory or -1 if error.
%macro bios_get_extended_memory_size 0
    mov     ax, 0x88
    int     0x15
    jc      short .error_2
    test    ax, ax              ; If size = 0
    je      short .error_2
    cmp     ah, 0x86            ; Unsupported function
    je      short .error_2
    cmp     ah, 0x80            ; Invalid command
    je      short .error_2
    ret
.error_2:
    mov     ax, -1
%endmacro
    
; Get the memory size for above 64MB.
; Output:
;   AX - KB between 1MB and 16MB. If error, then returns -1.
;   BX - Number of 64KB blocks above 16MB
%macro m_bios_get_memory_size_E801 0
    push    ecx
    push    edx
    xor     ecx, ecx        ; Clear all registers. This is needed for testing later
    xor     edx, edx
    mov     eax, 0x0000E801
    int     0x15    
    jc      short .error_3
    cmp     ah, 0x86        ; Unsupported function
    je      short .error_3
    cmp     ah, 0x80        ; Invalid command
    je      short .error_3
    jcxz    .use_ax         ; BIOS may have stored it in AX, BX or CX, DX. Test if CX is 0
    mov     ax, cx          ; It's not, so it should contain memory size; store it
    mov     bx, dx
    
.use_ax:
    pop     edx             ; Memory size is in ax and bx already, return it
    pop     ecx
    jmp     short .end
    
.error_3:
    mov     ax, -1          ; Return -1 as there is an error
    xor     bx, bx          ; Zero out BX
    pop     edx
    pop     ecx
.end:
%endmacro

; Get the memory map from the BIOS saying which areas of memory are reserved or available.
; Input:
;   ES:DI - The memory segment where the memory map table will be saved to.
; Output:
;   ESI - The number of memory map entries.
%macro m_bios_get_memory_map 0
    xor     ebx, ebx                        ; Start as 0, must preserve value after INT 0x15
    xor     esi, esi                        ; Number of entries
    mov     eax, 0x0000E820                 ; INT 0x15 sub function 0xE820
    mov     ecx, 24                         ; Memory map entry structure is 24 bytes
    mov     edx, 0x534D4150                 ; SMAP
    mov     [es:di + 20], dword 0x00000001  ; Force a valid ACPI 3.x entry
    int     0x15                            ; Get first entry
    jc      short .error_4                  ; If carry is set, then there was and error
    cmp     eax, 0x534D4150                 ; BIOS returns SMAP in EAX
    jne     short .error_4
    test    ebx, ebx                        ; If EBX = 0 then list is one entry
    je      short .error_4                  ; Then is worthless, so error.
    jmp     short .start
.next_entry:
    mov     eax, 0x0000E820
    mov     ecx, 24
    mov     edx, 0x534D4150
    mov     [es:di + 20], dword 0x00000001
    int     0x15                            ; Get next entry
    jc      short .done                     ; Carry set if end of list already reached
.start:
    jcxz    .skip_entry                     ; If actual returned bytes is 0, skip entry
    cmp     cl, 20                          ; Has it returned a a 24 byte ACPI 3.x response
    jbe     short .notext
    test    byte [es:di + 20], 0x01         ; If so, is the 'ignore this data' bit set
    jc      short .skip_entry
.notext:
    mov     ecx, dword [es:di + 8]          ; Save the lower 32 bit memory region lengths
    or      ecx, dword [es:di + 12]         ; OR with upper region to test for zero
    jz      short .skip_entry               ; If zero, the skip entry
    inc     esi                             ; Good entry so increment entry count and buffer offset
    add     di, 24
.skip_entry:
    cmp     ebx, 0                          ; If EBX is 0, list is done
    jne     short .next_entry               ; Get next entry if not zero
    jmp     short .done                     ; If zero then finish
.error_4:
    m_reboot_with_msg memory_map_error
.done:
    clc                                     ; Clear the carry as was set before this point because of the JC.
%endmacro
