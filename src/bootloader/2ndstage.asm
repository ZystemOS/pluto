; ------------------------------------------------------------
; Stage 2 of the bootloader
; ------------------------------------------------------------
%define boot_sector_location    (0x7C03)    ; The location of the boot sector
%define fat_segment             (0x0050)    ; The memory location to load the FAT into memory
%define stage_2_location        (0x7E00)    ; The location of the second stage bootloader

%define kernel_stack            (0x9FBFF)   ; The location of the start of the bottom of the stack

%define kernel_load_segment     (0x3000)    ; The segment when the kernel is loaded by the bootloader before A20 is enabled so can access above 1MB
%define kernel_load_location    (0x30000)   ; The location when the kernel is loaded by the bootloader before A20 is enabled so can access above 1MB
%define kernel_target_location  (0x100000)  ; The target location for the kernel to be loaded. Above 1MB.

%define memory_map_location     (0x20000)   ; This is where the memory map is loaded into. At bottom of 2nd stage bootloader
%define memory_map_segment      (0x02000)

%define boot_params_location    (0x7000)    ; The location where the boot parameters are save to for the kernel
%define SIGNATURE               (0x8A3C)    ; The signature of the parameters to test for valid parameters

    [bits    16]                    ; Tell the assembler that this is a 16bit program not 32bit
    [org    stage_2_location]
    
    jmp     stage_2_bootload_start

times (3 - ($ - $$)) db 0

boot_sector:
%include 'fat_descripter.asm'

; Macros to make code more readable. This doesn't take up memory here as they are copied where they are used

%include 'macros.asm'
%include 'descriptors_macros.asm'
%include 'enabling_a20.asm'
%include 'memory.asm'

stage_2_bootload_start:
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    sti
    
    ; Copy the boot sector
    m_copy_boot_sector
    
    ; Find the kernel file
    m_find_file kernel_filename, kernel_load_segment
    
    ; Read the kernel into the load segment
    m_read_file kernel_load_segment, fat_segment
    
    ; Save The size read, stored in BX, may change to number of sectors as kernel size gets bigger
    ; kernel_size is in bytes
    mov     word [kernel_size], bx
    mov     word [boot_parameters.kernel_len], bx
    
    ; Reset the disk
    m_reset_disk
    
    ; Write the loading message for the second stage
    m_write_line loading_msg
    
    ; Save the the boot parameters so the kernel can access them
    m_save_cursor
    
    ; Enable the a20 line
    m_enable_a20
    
    ; Read the size of the memory and store at 'boot_info'
    m_get_memory_size
    
    ; Set up and write into memory the interrupt descriptor table
    m_setup_idt
    
    ; Set up and write into memory the global descriptor table
    m_setup_gdt
    
    ; Load the tables
    m_load_gdt_and_idt
    
    ; Enable protected mode
    m_enable_protected
    
    jmp     0x08:stage_2_bootloader_32  ; Set CS to the code segment of the kernel in the GDT

; If there is a floppy disk error or a boot error, the call this function
boot_error:
    m_reboot_with_msg disk_error_msg    ; Print the disk error message
                                        ; Reboot

%include 'functions.asm'

idt_descriptor:
    dw 0x0000                           ; 256 entries of 8 bytes for the interrupt table
    dd 0x0000                           ; The location of the table, at 0x0000:0x0000
    
gdt_descriptor:
    dw 0x0017                           ; 3 tables of 8 bytes total (minus 1)
    dd 0x0800                           ; The location of the 3 tables, at 0x0000:0x0800, just bellow the IDT

kernel_filename     db "KERNEL  BIN", 0
disk_error_msg      db "Disk error", 0
loading_msg         db "Loading: 2nd stage bootloader", 0
reboot_msg          db "Press any key to reboot", 0
a20_error           db "a20 line not initialised", 0

loading_kernel      db "Loading: Kernel", 0x0A, 0

memory_map_error    db "Error getting memory map from BIOS INT 0x15 0xE820", 0

; Data storage
root_sectors        db 0,0
root_start          db 0,0
file_start          db 0,0

kernel_size         db 0,0

; Now in 32bit mode
    [bits    32]

stage_2_bootloader_32:
    m_set_up_segments
    
    lea     esi, [loading_kernel]
    call    print_string_32
    
    ; Move kernel to target location
    mov     esi, kernel_load_location
    mov     edi, kernel_target_location
    xor     ecx, ecx                    ; Zero out ECX for the kernel size
    mov     cx, word [kernel_size]
    shr     cx, 2                       ; Divide by 4 as now copying 4 bytes at a time
    cld
    rep     movsd
    
    jmp     kernel_target_location      ; Jump to the kernel, shouldn't return

%include '32bit_functions.asm'

times (3 * 512) - ($ - $$) db 0

    [absolute   boot_params_location]

boot_parameters:
    .signature          resw 1
    .cursor_pos_x       resb 1
    .cursor_pos_y       resb 1
    .memory_lower       resw 1
    .memory_upper       resw 1
    .memory_map_address resd 1
    .memory_map_length  resw 1
    .kernel_len         resd 1
