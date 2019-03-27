def get_test_cases(TestCase):
    return [
            TestCase("GDT init", [r"Init gdt", r"Done"]),
            TestCase("GDT tests", [r"GDT: Tested loading GDT"]),
            TestCase("IDT init", [r"Init idt", r"Done"]),
            TestCase("IDT tests", [r"IDT: Tested loading IDT"]),
            TestCase("PIC init", [r"Init pic", r"Done"]),
            TestCase("PIC tests", [r"PIC: Tested masking"]),
            TestCase("ISR init", [r"Init isr", r"Done"]),
            TestCase("ISR tests", [r"ISR: Tested registered handlers", r"ISR: Tested opened IDT entries"]),
            TestCase("IRQ init", [r"Init irq", r"Done"]),
            TestCase("IRQ tests", [r"IRQ: Tested registered handlers", r"IRQ: Tested opened IDT entries"]),
            TestCase("PIT init", [r"Init pit"]),
            TestCase("PIT init", [r".+"], r"\[DEBUG\] "),
            TestCase("PIT init", [r"Done"]),
            TestCase("PIT tests", [r"PIT: Tested init", r"PIT: Tested wait ticks", r"PIT: Tested wait ticks 2"]),
            TestCase("Paging init", [r"Init paging", r"Done"]),
            TestCase("Paging tests", [r"Paging: Tested accessing unmapped memory", r"Paging: Tested accessing mapped memory"]),
            TestCase("Syscalls init", [r"Init syscalls", r"Done"]),
            TestCase("Syscall tests", [r"Syscalls: Tested no args", r"Syscalls: Tested 1 arg", r"Syscalls: Tested 2 args", r"Syscalls: Tested 3 args", r"Syscalls: Tested 4 args", r"Syscalls: Tested 5 args"])
        ]
