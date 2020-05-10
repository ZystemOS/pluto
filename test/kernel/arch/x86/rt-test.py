def get_test_cases():
    return [
            "Init gdt",
            "GDT: Tested loading GDT",
            "Done gdt",

            "Init idt",
            "IDT: Tested loading IDT",
            "Done idt",

            "Init pic",
            "PIC: Tested masking",
            "Done pic",

            "Init isr",
            "ISR: Tested registered handlers", "ISR: Tested opened IDT entries",
            "Done isr",
            
            "Init irq",
            "IRQ: Tested registered handlers", "IRQ: Tested opened IDT entries",
            "Done irq",
            
            "Init paging",
            "Paging: Tested accessing unmapped memory", "Paging: Tested accessing mapped memory",
            "Done paging",

            "Init pit",
            "PIT: Tested init", "PIT: Tested wait ticks", "PIT: Tested wait ticks 2",
            "Done pit",

            "Init rtc",
            "RTC: Tested init", "RTC: Tested interrupts",
            "Done rtc",

            "Init syscalls",
            "Syscall: Tested all args",
            "Done syscalls",
        ]
