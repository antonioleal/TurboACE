/* The C library functions the firmware and FatFs use, for the soft CPU build
 * (-nostdlib). Plain byte loops: small, and speed does not matter next to the SD
 * card. Compiled with -fno-tree-loop-distribute-patterns so that GCC does not turn
 * these loops back into calls to themselves. The PC tests use the host's library. */
#include <stddef.h>
#include <string.h>

void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *dp = d;
    const unsigned char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

void *memmove(void *d, const void *s, size_t n)
{
    unsigned char *dp = d;
    const unsigned char *sp = s;
    if (dp < sp) while (n--) *dp++ = *sp++;
    else while (n--) dp[n] = sp[n];
    return d;
}

void *memset(void *d, int c, size_t n)
{
    unsigned char *dp = d;
    while (n--) *dp++ = (unsigned char) c;
    return d;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *ap = a, *bp = b;
    for (; n--; ap++, bp++) if (*ap != *bp) return *ap - *bp;
    return 0;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return (size_t) (p - s);
}

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++) != 0) {}
    return r;
}

char *strcat(char *d, const char *s)
{
    strcpy(d + strlen(d), s);
    return d;
}

char *strchr(const char *s, int c)
{
    for (;; s++) {
        if (*s == (char) c) return (char *) s;
        if (!*s) return NULL;
    }
}
