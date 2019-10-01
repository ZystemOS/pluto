def get_test_cases(TestCase):
    return [
            TestCase("GDT init", [r"Init gdt", r"Done"]),
            TestCase("GDT tests", [r"GDT: Tested loading GDT"]),
            TestCase("IDT init", [r"Init idt", r"Done"]),
            TestCase("IDT tests", [r"IDT: Tested loading IDT"]),
            TestCase("PIC init", [r"Init pic", r"Done"]),
            TestCase("PIC tests", [r"PIC: Tested masking"]),
            TestCase("PIT init", [r"Init pit", r".+", r"Done"]),
            TestCase("Syscalls init", [r"Init syscalls", r"Done"]),
            TestCase("Syscall tests", [r"Syscalls: Tested no args", r"Syscalls: Tested 1 arg", r"Syscalls: Tested 2 args", r"Syscalls: Tested 3 args", r"Syscalls: Tested 4 args", r"Syscalls: Tested 5 args"])
        ]
