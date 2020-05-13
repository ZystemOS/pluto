import atexit
import queue
import threading
import subprocess
import signal
import sys
import os
import importlib.util

msg_queue = queue.Queue(-1)
proc = None

def failure(msg):
    print("FAILURE: %s" %(msg))
    sys.exit(1)

def get_pre_archinit_cases():
    return [
            "c", "123",

            "Test INFO level", "Test INFO level with args a, 1", "Test INFO function", "Test INFO function with args a, 1",
            "Test DEBUG level", "Test DEBUG level with args a, 1", "Test DEBUG function", "Test DEBUG function with args a, 1",
            "Test WARNING level", "Test WARNING level with args a, 1", "Test WARNING function", "Test WARNING function with args a, 1",
            "Test ERROR level", "Test ERROR level with args a, 1", "Test ERROR function", "Test ERROR function with args a, 1",

            "Init mem",
            "Done mem",

            "Init panic",
            "Done panic",

            "Init pmm",
            "PMM: Tested allocation",
            "Done pmm",

            "Init vmm",
            "VMM: Tested allocations",
            "Done vmm",
            "Init arch",
        ]

def get_post_archinit_cases():
    return [
            "Arch init done",
            "Init vga",
            "VGA: Tested max scan line", "VGA: Tested cursor shape", "VGA: Tested updating cursor",
            "Done vga",

            "Init tty",
            "TTY: Tested globals", "TTY: Tested printing",
            "Done tty",

            "Init heap", "Done heap",

            "Init done",

            "Kernel panic: integer overflow", ": panic", ": panic.runtimeTests", ": kmain", ": start_higher_half",
        ]

def read_messages(proc):
    while True:
        line = proc.stdout.readline().decode("utf-8")
        msg_queue.put(line)

def cleanup():
    global proc
    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)

def check_cases(cases):
    for case_1 in cases:
        for case_2 in cases:
            if case_1 != case_2:
                if case_1 in case_2 or case_2 in case_1:
                    print("Conflicting cases: {}, {}\n".format(case_1, case_2))
                    return True
    
    return False

if __name__ == "__main__":
    arch = sys.argv[1]
    zig_path = sys.argv[2]
    spec = importlib.util.spec_from_file_location("arch", "test/kernel/arch/" + arch + "/rt-test.py")
    arch_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(arch_module)

    # The list of log statements to look for before arch init is called +
    # All log statements to look for, including the arch-specific ones +
    # The list of log statements to look for after arch init is called
    cases = get_pre_archinit_cases() + arch_module.get_test_cases() + get_post_archinit_cases()

    if check_cases(cases):
        sys.exit(1)

    proc = subprocess.Popen(zig_path + " build run -Drt-test=true", stdout=subprocess.PIPE, shell=True, preexec_fn=os.setsid)
    atexit.register(cleanup)
    
    read_thread = threading.Thread(target=read_messages, args=(proc,))
    read_thread.daemon = True
    read_thread.start()

    while cases:
        try:
            line = msg_queue.get(block=True, timeout=5)
        except queue.Empty:
            if cases:
                print("Missing cases: " + cases)
            failure("Timed out")
        
        line = line.strip()

        # Print the line so can see what is going on
        print(line)

        # If there is a FAILURE message in the log, then fail the testing
        if "FAILURE" in line:
            failure("Test failed")
        
        # Remove the line from the cases, this is slow for now
        cases = [item for item in cases if item not in line]

    print("Test complete")

    sys.exit(0)
