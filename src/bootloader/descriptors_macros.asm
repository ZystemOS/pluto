; Set up the interrupt descriptor table
; This is to be stored at 0x0000:0x0000
%macro m_setup_idt 0
    push    es
    push    di
    xor     ax, ax
    mov     es, ax
    mov     di, 0x0000
    mov     cx, 2048                    ; Write 2048 byte of zero so now into the IDT
    cld
    rep     stosb
%endmacro

; Set up the global descriptor table
; This is to be stored at 0x0000:0x0800
%macro m_setup_gdt 0

    ; NULL Descriptor:
    mov     cx, 4                       ; Write the NULL descriptor,
    rep     stosw                       ; which is 4 zero-words.
    
    ; Code segment descriptor:
    mov     [es:di], word 0xFFFF        ; limit = 0xFFFF (since granularity bit is set, this is 4 GB)
    mov     [es:di + 2], word 0x0000    ; base  = 0x0000
    mov     [es:di + 4], byte 0x00      ; base
    mov     [es:di + 5], byte 0x9A      ; access = 1001 1010; segment present, ring 0, S=code/data, type=0xA (code, execute/read)
    mov     [es:di + 6], byte 0xCF      ; granularity = 1100 1111; limit = 0xf, AVL=0, L=0, 32bit, G=1
    mov     [es:di + 7], byte 0x00      ; base
    add     di, 8
    
    ; Data segment descriptor:
    mov     [es:di], word 0xFFFF        ; limit = 0xFFFF (since granularity bit is set, this is 4 GB)
    mov     [es:di + 2], word 0x0000    ; base  = 0x0000
    mov     [es:di + 4], byte 0x00      ; base
    mov     [es:di + 5], byte 0x92      ; access = 1001 0010; segment present, ring 0, S=code/data, type=0x2 (data, read/write)
    mov     [es:di + 6], byte 0xCF      ; granularity = 1100 1111; limit = 0xf, AVL=0, L=0, 32bit, G=1
    mov     [es:di + 7], byte 0x00      ; base
    pop     di
    pop     es
%endmacro

; Tell the CPU of the GDT and IDT
%macro m_load_gdt_and_idt 0
    cli
    lgdt    [gdt_descriptor]
    lidt    [idt_descriptor]
%endmacro
