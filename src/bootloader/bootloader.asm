; ---------------------------------------------------------------------
; Here is some information for you so can understand the whole thing :)
; Using a 1440KB 3.5" Floppy for the bootloader
; ---------------------------------------------------------------------

%define boot0_location          (0x7C00)    ; The location that BOOT0 is load to by the BIOS
%define boot_signature          (0xAA55)    ; The boot signature that is needed at the end of the 512 bytes so that it is recognized as a boot device.
%define fat_segment             (0x0050)    ; The memory location to load the FAT into memory
;%define stage_2_load_segment   (0x0200)    ; The location of the second stage bootloader
%define stage_2_load_segment    (0x07E0)

    [bits    16]                ; Tell the assembler that this is a 16bit program not 32bit
    [org    boot0_location]    ; As the bootloader is loaded at 0x7C00, all addressing will be relative to this location

    ; Will need to jump over the FAT16 header. 3 Bytes are allowed before the header
    ; so can only use a relative/short jump.
    jmp     short bootloader_start

; Need to pad to a total of 3 bytes so far.
; This is so to comply with the FAT16 header.
; We could use a NOP instruction as the previous instruction (JMP) is 2 bytes and NOP is 1 byte
; See https://www.win.tue.nl/~aeb/linux/fs/fat/fat-1.html
; Bytes 0-2
times (3 - ($ - $$)) db 0

%include 'fat_descripter.asm'

; Bytes 62-509

%include 'macros.asm'

bootloader_start:
    ; The BIOS can load us (the bootloader) at address 0x000:7C00 or 0x7C00:0000
    ; This is in fact the same address
    ; So we need to normalise this by using a long jump
    jmp     long 0x0000:start_boot0_16bit

start_boot0_16bit:
    ; ------------------------------------------------------------------------
    ; Set up the memory segment for accessing memory the old way.
    ; ------------------------------------------------------------------------
    
    cli                                        ; Disable interrupts so not mess up the declarations of the segments
    
    mov     byte [Logical_drive_number], dl    ; Save what drive we booted from (should be 0x00) into our boot parameter block above
    
    mov     ax, cs                            ; Set all the sectors to start to begin with. Can get this from the code segment. Should be 0x00
    mov     ds, ax                            ; Set the data segment at the beginning of the bootloader location
    mov     es, ax                            ; Set the extra1 segment at the beginning of the bootloader location
    mov     ss, ax                            ; Set the stack segment at the beginning of the bootloader location
    
    mov     sp, boot0_location                ; Set the stack pointer to the bootloader and grows down to 0x0.
    
    sti                                        ; Enable interrupts
    
    ; ------------------------------------------------------------------------
    ; Finished setting up the memory segment for accessing memory the old way.
    ; ------------------------------------------------------------------------
    
    ; Reset the floppy disk
    ; Now need to reset the floppy drive so that we can get information from it
    m_reset_disk
    
    ; Print the loading message
    m_write_line loading_msg
    
    ; Find the 2ndstage bootloader in the root directory
    m_find_file stage_2_filename, stage_2_load_segment
    
    ; Load the FAT table into memory
    m_read_fat fat_segment
    
    ; Read the 2ndstage bootloader into memory
    m_read_file stage_2_load_segment, fat_segment
    
    ; ------------------------------------------------------------------------
    ; Start the second stage bootloader
    ; ------------------------------------------------------------------------
    
    ; Jump to second stage start of code:
    jmp     long stage_2_load_segment:0000h


; If there is a floppy disk error or a boot error, the call this function
boot_error:
    m_reboot_with_msg disk_error_msg    ; Print the disk error message
                                        ; Reboot

; Include the functions that can be called
%include 'functions.asm'

; Messages
disk_error_msg      db "Disk error", 0
loading_msg         db "Loading: 1st stage bootloader", 0
reboot_msg          db "Press any key to reboot", 0

; Stage 2 bootloader file name to find
stage_2_filename    db "2NDSTAGEBIN", 0

; Data storage
root_sectors        db 0,0
root_start          db 0,0
file_start          db 0,0

; Pad the rest of the file with zeros
; Bytes 510-511
times 510 - ($ - $$) db 0
; Add the boot signature at the end
dw boot_signature
