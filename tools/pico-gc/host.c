#include <stdio.h>
#include <stdlib.h>

extern int gc_run_tests(void);

void gc_report(const char *name, size_t len, int status)
{
    printf("GC %s %.*s\n", status < 0 ? "RUN" : status ? "FAIL" : "PASS", (int)len, name);
}

void gc_panic(const char *message, size_t len)
{
    fprintf(stderr, "GC PANIC %.*s\n", (int)len, message);
    exit(1);
}

int main(void)
{
    return gc_run_tests() ? 1 : 0;
}
