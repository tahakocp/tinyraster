/* Reads "tri cycle x y rrggbb" from stdin, paints a WxH image, writes an
 * uncompressed PNG to stdout. No libraries: stored deflate blocks only. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint32_t crc_table[256];

static void crc_init(void)
{
    for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = n;
        for (int k = 0; k < 8; k++) c = c & 1 ? 0xedb88320u ^ (c >> 1) : c >> 1;
        crc_table[n] = c;
    }
}

static uint32_t crc(uint32_t c, const uint8_t *p, size_t n)
{
    c = ~c;
    while (n--) c = crc_table[(c ^ *p++) & 255] ^ (c >> 8);
    return ~c;
}

static void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static void chunk(const char *type, const uint8_t *data, uint32_t len)
{
    uint8_t hdr[8], tail[4];
    be32(hdr, len);
    for (int i = 0; i < 4; i++) hdr[4 + i] = (uint8_t)type[i];
    fwrite(hdr, 1, 8, stdout);
    if (len) fwrite(data, 1, len, stdout);
    uint32_t c = crc(0, hdr + 4, 4);
    if (len) c = crc(c, data, len);
    be32(tail, c);
    fwrite(tail, 1, 4, stdout);
}

int main(int argc, char **argv)
{
    if (argc != 3) { fprintf(stderr, "usage: mkpng W H < pixels > out.png\n"); return 2; }
    int w = atoi(argv[1]), h = atoi(argv[2]);
    size_t stride = 1 + (size_t)w * 3, raw_len = stride * h;
    uint8_t *raw = calloc(raw_len, 1);
    int tri, cyc, x, y; unsigned rgb;
    while (scanf("%d %d %d %d %x", &tri, &cyc, &x, &y, &rgb) == 5) {
        if (x < 0 || x >= w || y < 0 || y >= h) continue;
        uint8_t *p = raw + y * stride + 1 + x * 3;
        p[0] = rgb >> 16; p[1] = rgb >> 8; p[2] = rgb;
    }
    /* zlib stream: header, stored blocks of up to 65535 bytes, adler32 */
    size_t nblocks = (raw_len + 65534) / 65535;
    size_t zlen = 2 + raw_len + 5 * nblocks + 4;
    uint8_t *z = malloc(zlen), *q = z;
    *q++ = 0x78; *q++ = 0x01;
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < raw_len; i++) { a = (a + raw[i]) % 65521; b = (b + a) % 65521; }
    for (size_t off = 0; off < raw_len; off += 65535) {
        size_t n = raw_len - off < 65535 ? raw_len - off : 65535;
        *q++ = off + n == raw_len;
        *q++ = n & 255; *q++ = n >> 8; *q++ = ~n & 255; *q++ = (~n >> 8) & 255;
        for (size_t i = 0; i < n; i++) *q++ = raw[off + i];
    }
    be32(q, (b << 16) | a); q += 4;

    static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    uint8_t ihdr[13];
    be32(ihdr, w); be32(ihdr + 4, h);
    ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = ihdr[11] = ihdr[12] = 0;
    crc_init();
    fwrite(sig, 1, 8, stdout);
    chunk("IHDR", ihdr, 13);
    chunk("IDAT", z, (uint32_t)(q - z));
    chunk("IEND", 0, 0);
    return 0;
}
