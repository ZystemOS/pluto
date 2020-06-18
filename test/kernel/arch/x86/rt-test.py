def get_test_cases(TestCase):
    return [
            TestCase("GDT init", [r"Init gdt"]),
            TestCase("GDT tests", [r"GDT: Tested loading GDT"]),
            TestCase("GDT done", [r"Done gdt"]),

            TestCase("IDT init", [r"Init idt"]),
            TestCase("IDT tests", [r"IDT: Tested loading IDT"]),
            TestCase("IDT done", [r"Done idt"]),

            TestCase("PIC init", [r"Init pic"]),
            TestCase("PIC tests", [r"PIC: Tested masking"]),
            TestCase("PIC done", [r"Done pic"]),

            TestCase("ISR init", [r"Init isr"]),
            TestCase("ISR tests", [r"ISR: Tested registered handlers", r"ISR: Tested opened IDT entries"]),
            TestCase("ISR done", [r"Done isr"]),
            
            TestCase("IRQ init", [r"Init irq"]),
            TestCase("IRQ tests", [r"IRQ: Tested registered handlers", r"IRQ: Tested opened IDT entries"]),
            TestCase("IRQ done", [r"Done irq"]),
            
            TestCase("Paging init", [r"Init paging"]),
            TestCase("Paging tests", [r"Paging: Tested accessing unmapped memory", r"Paging: Tested accessing mapped memory"]),
            TestCase("Paging done", [r"Done paging"]),

            TestCase("PIT init", [r"Init pit"]),
            TestCase("PIT init", [r".+"], r"\[DEBUG\] "),
            TestCase("PIT tests", [r"PIT: Tested init", r"PIT: Tested wait ticks", r"PIT: Tested wait ticks 2"]),
            TestCase("PIT done", [r"Done pit"]),

            TestCase("RTC init", [r"Init rtc"]),
            TestCase("RTC tests", [r"RTC: Tested init", r"RTC: Tested interrupts"]),
            TestCase("RTC done", [r"Done rtc"]),

            TestCase("Syscalls init", [r"Init syscalls"]),
            TestCase("Syscalls tests", [r"Syscalls: Tested no args", r"Syscalls: Tested 1 arg", r"Syscalls: Tested 2 args", r"Syscalls: Tested 3 args", r"Syscalls: Tested 4 args", r"Syscalls: Tested 5 args"]),
            TestCase("Syscalls done", [r"Done syscalls"]),
            TestCase("VGA init", [r"Init vga"]),
            TestCase("VGA tests", [r"VGA: Tested max scan line", r"VGA: Tested cursor shape", r"VGA: Tested updating cursor"]),
            TestCase("VGA done", [r"Done vga"]),
            TestCase("TTY tests", [r"TTY: Tested globals", r"TTY: Tested printing"]),

        ]
