import atexit
import queue
import threading
import subprocess
import signal
import re
import sys
import datetime
import os
import importlib.util

msg_queue = queue.Queue(-1)
proc = None

class TestCase:
    def __init__(self, name, expected, prefix=r"\[INFO\] "):
        self.name = name
        self.expected = expected
        self.prefix = prefix

def failure(msg):
    print("FAILURE: %s" %(msg))
    sys.exit(1)

def test_failure(case, exp, expected_idx, found):
    failure("%s #%d, expected '%s', found '%s'" %(case.name, expected_idx + 1, exp, found))

def test_pass(case, exp, expected_idx, found):
    print("PASS: %s #%d, expected '%s', found '%s'" %(case.name, expected_idx + 1, exp, found))

def get_pre_archinit_cases():
    return [
            TestCase("Serial tests", [r"c", r"123"], ""),
            TestCase("Log info tests", [r"Test INFO level", r"Test INFO level with args a, 1", r"Test INFO function", r"Test INFO function with args a, 1"], "\[INFO\] "),
            TestCase("Log debug tests", [r"Test DEBUG level", r"Test DEBUG level with args a, 1", r"Test DEBUG function", r"Test DEBUG function with args a, 1"], "\[DEBUG\] "),
            TestCase("Log warning tests", [r"Test WARNING level", r"Test WARNING level with args a, 1", r"Test WARNING function", r"Test WARNING function with args a, 1"], "\[WARNING\] "),
            TestCase("Log error tests", [r"Test ERROR level", r"Test ERROR level with args a, 1", r"Test ERROR function", r"Test ERROR function with args a, 1"], "\[ERROR\] "),
            TestCase("Mem init", [r"Init mem", r"Done"]),
            TestCase("Arch init starts", [r"Init arch \w+"])
        ]

def get_post_archinit_cases():
    return [
            TestCase("Arch init finishes", [r"Arch init done"]),
            TestCase("Panic init", [r"Init panic", r"Done"]),
            TestCase("VGA init", [r"Init vga", r"Done"]),
            TestCase("VGA tests", [r"VGA: Tested max scan line", r"VGA: Tested cursor shape", r"VGA: Tested updating cursor"]),
            TestCase("TTY init", [r"Init tty", r"Done"]),
            TestCase("TTY tests", [r"TTY: Tested globals", r"TTY: Tested printing"]),
            TestCase("Init finishes", [r"Init done"]),
            TestCase("Panic tests", [r"Kernel panic: integer overflow", r"c[a-z\d]+: panic", r"c[a-z\d]+: panic.runtimeTests", r"c[a-z\d]+: kmain", r"c[a-z\d]+: start_higher_half"], "\[ERROR\] ")
        ]

def read_messages(proc):
    while True:
        line = proc.stdout.readline().decode("utf-8")
        msg_queue.put(line)

def cleanup():
    global proc
    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)

if __name__ == "__main__":
    arch = sys.argv[1]
    zig_path = sys.argv[2]
    spec = importlib.util.spec_from_file_location("arch", "test/kernel/arch/" + arch + "/rt-test.py")
    arch_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(arch_module)

    # The list of log statements to look for before arch init is called +
    # All log statements to look for, including the arch-specific ones +
    # The list of log statements to look for after arch init is called
    cases = get_pre_archinit_cases() + arch_module.get_test_cases(TestCase) + get_post_archinit_cases()

    if len(cases) > 0:
        proc = subprocess.Popen(zig_path + " build run -Drt-test=true", stdout=subprocess.PIPE, shell=True, preexec_fn=os.setsid)
        atexit.register(cleanup)
        case_idx = 0
        read_thread = threading.Thread(target=read_messages, args=(proc,))
        read_thread.daemon = True
        read_thread.start()
        # Go through the cases
        while case_idx < len(cases):
            case = cases[case_idx]
            expected_idx = 0
            # Go through the expected log messages
            while expected_idx < len(case.expected):
                e = case.prefix + case.expected[expected_idx]
                try:
                    line = msg_queue.get(block=True, timeout=5)
                except queue.Empty:
                    failure("Timed out waiting for '%s'" %(e))
                line = line.strip()
                pattern = re.compile(e)
                # Pass if the line matches the expected pattern, else fail
                if pattern.fullmatch(line):
                    test_pass(case, e, expected_idx, line)
                else:
                    test_failure(case, e, expected_idx, line)
                expected_idx += 1
            case_idx += 1
    sys.exit(0)
