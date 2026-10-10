"""Run the collector checks on the Pico SDK USB console."""

import argparse
import time

import serial

EXPECTED = {
    "cycles", "roots", "exhaustion", "coalescing", "alignment", "buffers",
    "deep_graph", "bounded_stress", "bounds",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="/dev/ttyACM0")
    args = parser.parse_args()
    with serial.Serial(args.port, 115200, timeout=0.2, exclusive=True) as port:
        port.reset_input_buffer()
        port.write(b"r")
        port.flush()
        deadline = time.monotonic() + 45
        passed = set()
        while time.monotonic() < deadline:
            line = port.readline().decode("ascii", errors="replace").strip()
            if not line.startswith("GC "):
                continue
            print(line, flush=True)
            if line.startswith(("GC FAIL ", "GC PANIC ")):
                return 1
            if line.startswith("GC PASS "):
                passed.add(line.removeprefix("GC PASS "))
            if line.startswith("GC RESULT "):
                return 0 if line.startswith("GC RESULT PASS failures=0 ") and passed == EXPECTED else 1
        print("No complete collector result within 45 seconds.", flush=True)
        return 1
    return None


if __name__ == "__main__":
    raise SystemExit(main())
