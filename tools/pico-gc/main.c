#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/stdio_usb.h"

extern int gc_run_tests(void);

void gc_report(const char *name, size_t len, int status)
{
    printf("GC %s %.*s\n", status < 0 ? "RUN" : status ? "FAIL" : "PASS", (int)len, name);
    stdio_flush();
}

void gc_panic(const char *message, size_t len)
{
    printf("GC PANIC %.*s\n", (int)len, message);
    stdio_flush();
    for (;;) tight_loop_contents();
}

int main(void)
{
    stdio_init_all();
    for (;;)
    {
        if (getchar_timeout_us(100000) != 'r') continue;
        uint64_t start = time_us_64();
        int failures = gc_run_tests();
        printf("GC RESULT %s failures=%d heap_bytes=131072 elapsed_us=%llu\n",
               failures ? "FAIL" : "PASS", failures,
               (unsigned long long)(time_us_64() - start));
        stdio_flush();
    }
}
