cmake_minimum_required(VERSION 3.13)
set(PICO_BOARD pico2_w CACHE STRING "Pico board")
include(${PICO_SDK_PATH}/external/pico_sdk_import.cmake)
project(element0_gc_test C CXX ASM)
pico_sdk_init()

find_program(ZIG zig REQUIRED)
get_filename_component(ELEMENT0_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(GC_OBJECT "${CMAKE_CURRENT_BINARY_DIR}/checks.o")
add_custom_command(
    OUTPUT "${GC_OBJECT}"
    COMMAND "${ZIG}" build-obj -OReleaseSafe -target thumb-freestanding-eabi
        -mcpu=cortex_m33 --dep managed_heap
        "-Mroot=${CMAKE_CURRENT_SOURCE_DIR}/checks.zig"
        "-Mmanaged_heap=${ELEMENT0_ROOT}/src/elz/managed_heap.zig"
        "-femit-bin=${GC_OBJECT}"
    DEPENDS checks.zig "${ELEMENT0_ROOT}/src/elz/managed_heap.zig"
    VERBATIM
)
set_source_files_properties("${GC_OBJECT}" PROPERTIES EXTERNAL_OBJECT TRUE GENERATED TRUE)
add_executable(gc_test main.c "${GC_OBJECT}")
target_link_libraries(gc_test pico_stdlib)
target_compile_definitions(gc_test PRIVATE PICO_STACK_SIZE=0x4000)

# Zig's safety diagnostics need more than the default 4 KiB scratch bank.
pico_set_linker_script_var(gc_test RAM_LENGTH 0x7c000)
pico_set_linker_script_var(gc_test SCRATCH_Y_ORIGIN 0x2007c000)
pico_set_linker_script_var(gc_test SCRATCH_Y_LENGTH 0x4000)
pico_enable_stdio_usb(gc_test 1)
pico_enable_stdio_uart(gc_test 0)
pico_add_extra_outputs(gc_test)
