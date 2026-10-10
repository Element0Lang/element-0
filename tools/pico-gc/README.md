## Pico Collector Test

This experiment tests the standalone collector on a Raspberry Pi Pico 2 WH.
It uses the Pico SDK from the microcontroller playground checkout and runs without an OS.
The Zig object links against the SDK's C startup and USB code.
Element 0 itself is not included.

### Results

Verified on the connected Pico 2 WH on October 10, 2026, with Zig 0.17.0.
All nine checks passed with a 128-KiB heap and ReleaseSafe checks enabled.

- Rooted cycles and reclamation after root removal
- Root replacement and removal in any order
- Heap exhaustion without losing rooted objects
- Reuse of adjacent swept blocks
- Alignment of objects to 256 bytes in an unaligned region
- Tracing and reallocation of owned buffers
- A chain of 1,500 objects
- 10,000 allocation and collection cycles with bounded memory use
- Guard bytes outside the heap

The USB result was:

```text
GC RESULT PASS failures=0 heap_bytes=131072 elapsed_us=182329
```

The elapsed time includes the full test run and USB reporting.
It is not a measurement of collection pauses. The same checks also passed on the host.
The original flash image was restored and verified after the test, and the USB console confirmed that NuttX was running again.

### Build

Set `PLAYGROUND` to the existing microcontroller playground checkout and set `ZIG` to the Zig 0.17.0 executable.
Run these commands from the Element 0 root.
They write build output to `zig-out/pico-gc` and do not change the playground.

```bash
nix develop "$PLAYGROUND" --command cmake -G Ninja \
  -S tools/pico-gc -B zig-out/pico-gc \
  -DPICO_SDK_PATH="$PLAYGROUND/external/pico-sdk" -DZIG="$ZIG"
nix develop "$PLAYGROUND" --command cmake --build zig-out/pico-gc -j4
```

The UF2 is built for `pico2_w` and the Cortex-M33 cores. Zig uses the soft-float
calling convention to match the SDK.
A 16-KiB stack is reserved at the top of the main SRAM because Zig's safety diagnostics do not fit in a 4-KiB scratch bank.

### Flash and Run

Put the Pico in BOOTSEL mode. Save its current flash before loading the test.
The backup may contain saved settings, so keep it private and out of version control.
The commands assume one connected Pico.

```bash
umask 077
nix develop "$PLAYGROUND" --command picotool save -a -v --family rp2350-arm-s \
  zig-out/pico-gc/pico-before-gc-test.uf2
nix develop "$PLAYGROUND" --command picotool load -v -x zig-out/pico-gc/gc_test.uf2
"$PLAYGROUND/.venv/bin/python" tools/pico-gc/read_results.py
```

The reader uses the playground's existing pyserial dependency.
Pass `--port` if the Pico has a different serial device name.
The firmware runs a suite each time it receives `r`.
The reader requires all nine passes and a successful final result, and exits with an error on a failure, panic, or timeout.

The test firmware supports the SDK's USB reset interface.
Restore the original flash without another BOOTSEL button press:

```bash
nix develop "$PLAYGROUND" --command picotool load -f -v -x \
  zig-out/pico-gc/pico-before-gc-test.uf2
```

### Host Check

The host runs the same Zig test functions through a C driver.

```bash
"$ZIG" build-obj -OReleaseSafe -fcompiler-rt --dep managed_heap \
  -Mroot=tools/pico-gc/checks.zig -Mmanaged_heap=src/elz/managed_heap.zig \
  -femit-bin=zig-out/gc-host-checks.o
cc -no-pie tools/pico-gc/host.c zig-out/gc-host-checks.o -o zig-out/gc-host-checks
./zig-out/gc-host-checks
```
