; ------------------------------------------
; This will be where the floppy FAT12 header
; Bytes 3-61
; https://technet.microsoft.com/en-us/library/cc976796.aspx
; Values are those used by IBM for 1.44 MB, 3.5" diskette
; ------------------------------------------

OEM_name				db "DeanOS  "		; Bytes 03-10 - OEM name (Original Equipment Manufacturer) The name for the bootloader/OS
Bytes_per_sector		dw 512				; Bytes 11-12 - Number of bytes per sector (usually 512 bytes)
Sectors_per_cluster		db 1				; Bytes 13    - Number of sectors per cluster, is 1 because in FAT12 a cluster is the same as a sector
Reserved_sectors		dw 1				; Bytes 14-15 - For FAT12 is 1
FAT_tables				db 2				; Bytes 16    - Number of FAT tables (usually 2)
Root_directory_size		dw 224				; Bytes 17-18 - Size of root directory entries 224 for FAT12
Sectors_in_filesystem	dw 2880				; Bytes 19-20 - Total number of sectors in the file system (usually 2880)
Media_descriptor_type	db 0xF0				; Bytes 21    - Media descriptor: 3.5" floppy 1440KB
Sectors_per_FAT			dw 9				; Bytes 22-23 - Number of sectors per FAT is 9
Sectors_per_track		dw 18				; Bytes 24-25 - Number of sectors per track is 12 but found to be 9
Head_count				dw 2				; Bytes 26-27 - Number of heads/sides of the floppy (usually 2)
Hidden_sectors			dd 0				; Bytes 28-31 - Number of hidden sectors (usually 0)
Total_sectors			dd 0				; Bytes 32-35 - Total number of sectors in file system
Logical_drive_number	db 0				; Bytes 36    - Logical drive number (0)
Reserved				db 0				; Bytes 37    - Reserved sectors
Extended_signature		db 0x29				; Bytes 38    - Indicates that there 3 more fields
Serial_number			dd 0xA1B2C3D4		; Bytes 39-42 - Serial number, can be anything
Volume_lable			db "OS bootdisk"	; Bytes 43-53 - Name of the volume, 11 characters
Filesystem_type			db "FAT12   "		; Bytes 54-61 - File system type (FAT12), 8 characters

; ------------------------------------------
; End of FAT12 header
; ------------------------------------------
