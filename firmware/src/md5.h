/* MD5 (RFC 1321), for checking /ace.rom. md5.c */
#ifndef MD5_H
#define MD5_H

#include <stdint.h>

struct md5 { uint32_t h[4]; uint64_t len; uint8_t buf[64]; unsigned n; };

void md5_init(struct md5 *m);
void md5_add(struct md5 *m, const void *data, unsigned len);
void md5_done(struct md5 *m, uint8_t digest[16]);

#endif
