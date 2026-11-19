/* Reference model for tinyraster. Same integer math as the RTL, written for
 * clarity rather than speed. Plain int64, no clamping tricks. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef SW
#define SW 64
#endif
#ifndef SH
#define SH 48
#endif

typedef struct { int x[3], y[3]; int c[3][3]; } tri_t;

static int64_t tdiv(int64_t n, int64_t d) { return n / d; } /* truncates toward zero */

static int tl(int ax, int ay, int bx, int by)
{
    int dx = bx - ax, dy = by - ay;
    return dy < 0 || (dy == 0 && dx > 0);
}

static int imin3(int a, int b, int c) { int m = a < b ? a : b; return m < c ? m : c; }
static int imax3(int a, int b, int c) { int m = a > b ? a : b; return m > c ? m : c; }

/* Calls emit for every covered pixel in scan order. Returns pixel count. */
static int raster(tri_t t, void (*emit)(int x, int y, int r, int g, int b, void *u), void *u)
{
    int64_t area = (int64_t)(t.x[1] - t.x[0]) * (t.y[2] - t.y[0])
                 - (int64_t)(t.y[1] - t.y[0]) * (t.x[2] - t.x[0]);
    if (area == 0) return 0;
    if (area < 0) {
        int tx = t.x[1], ty = t.y[1], tc[3];
        memcpy(tc, t.c[1], sizeof tc);
        t.x[1] = t.x[2]; t.y[1] = t.y[2]; memcpy(t.c[1], t.c[2], sizeof tc);
        t.x[2] = tx;     t.y[2] = ty;     memcpy(t.c[2], tc, sizeof tc);
        area = -area;
    }
    int minx = imin3(t.x[0], t.x[1], t.x[2]), maxx = imax3(t.x[0], t.x[1], t.x[2]);
    int miny = imin3(t.y[0], t.y[1], t.y[2]), maxy = imax3(t.y[0], t.y[1], t.y[2]);
    if (minx < 0) minx = 0;
    if (miny < 0) miny = 0;
    if (maxx > SW - 1) maxx = SW - 1;
    if (maxy > SH - 1) maxy = SH - 1;
    if (minx > maxx || miny > maxy) return 0;

    /* edge i is opposite vertex i: (a,b) = (v1,v2), (v2,v0), (v0,v1) */
    int ai[3] = {1, 2, 0}, bi[3] = {2, 0, 1};
    int64_t A[3], B[3], w0[3];
    int top_left[3];
    for (int i = 0; i < 3; i++) {
        int a = ai[i], b = bi[i];
        A[i] = -(int64_t)(t.y[b] - t.y[a]);
        B[i] =  (int64_t)(t.x[b] - t.x[a]);
        w0[i] = B[i] * (miny - t.y[a]) + A[i] * (minx - t.x[a]);
        top_left[i] = tl(t.x[a], t.y[a], t.x[b], t.y[b]);
    }
    int64_t q0[3], gx[3], gy[3];
    for (int k = 0; k < 3; k++) {
        int64_t n = 0, sx = 0, sy = 0;
        for (int i = 0; i < 3; i++) {
            n  += (int64_t)t.c[i][k] * w0[i];
            sx += (int64_t)t.c[i][k] * A[i];
            sy += (int64_t)t.c[i][k] * B[i];
        }
        q0[k] = tdiv(n * 65536, area);
        gx[k] = tdiv(sx * 65536, area);
        gy[k] = tdiv(sy * 65536, area);
    }
    int count = 0;
    int64_t wr[3] = {w0[0], w0[1], w0[2]}, qr[3] = {q0[0], q0[1], q0[2]};
    for (int y = miny; y <= maxy; y++) {
        int64_t w[3] = {wr[0], wr[1], wr[2]}, q[3] = {qr[0], qr[1], qr[2]};
        for (int x = minx; x <= maxx; x++) {
            int in = 1;
            for (int i = 0; i < 3; i++)
                if (!(w[i] > 0 || (w[i] == 0 && top_left[i]))) in = 0;
            if (in) {
                int c[3];
                for (int k = 0; k < 3; k++) {
                    int64_t v = (q[k] + 32768) >> 16;
                    c[k] = v < 0 ? 0 : v > 255 ? 255 : (int)v;
                }
                emit(x, y, c[0], c[1], c[2], u);
                count++;
            }
            for (int i = 0; i < 3; i++) w[i] += A[i];
            for (int k = 0; k < 3; k++) q[k] += gx[k];
        }
        for (int i = 0; i < 3; i++) wr[i] += B[i];
        for (int k = 0; k < 3; k++) qr[k] += gy[k];
    }
    return count;
}

static int read_tri(FILE *f, tri_t *t)
{
    unsigned c[3];
    int n = fscanf(f, "%d %d %d %d %d %d %x %x %x", &t->x[0], &t->y[0], &t->x[1], &t->y[1],
                   &t->x[2], &t->y[2], &c[0], &c[1], &c[2]);
    if (n != 9) return 0;
    for (int i = 0; i < 3; i++) {
        t->c[i][0] = c[i] >> 16 & 255;
        t->c[i][1] = c[i] >> 8 & 255;
        t->c[i][2] = c[i] & 255;
    }
    return 1;
}

static void print_tri(const tri_t *t)
{
    printf("%d %d %d %d %d %d %02x%02x%02x %02x%02x%02x %02x%02x%02x\n", t->x[0], t->y[0], t->x[1],
           t->y[1], t->x[2], t->y[2], t->c[0][0], t->c[0][1], t->c[0][2], t->c[1][0], t->c[1][1],
           t->c[1][2], t->c[2][0], t->c[2][1], t->c[2][2]);
}

static uint64_t rng_s;
static uint32_t rnd(void)
{
    rng_s = rng_s * 6364136223846793005ULL + 1442695040888963407ULL;
    return (uint32_t)(rng_s >> 33);
}
static int rrange(int lo, int hi) { return lo + (int)(rnd() % (uint32_t)(hi - lo + 1)); }

static void gen(int n, uint64_t seed)
{
    rng_s = seed * 2654435761u + 1;
    for (int i = 0; i < n; i++) {
        tri_t t;
        int mode = i % 8;
        for (int v = 0; v < 3; v++) {
            if (mode < 3) { t.x[v] = rrange(-8, SW + 8); t.y[v] = rrange(-8, SH + 8); }
            else if (mode == 3) { t.x[v] = rrange(-2048, 2047); t.y[v] = rrange(-2048, 2047); }
            else if (mode == 4) { t.x[v] = rrange(20, 24); t.y[v] = rrange(10, 14); }
            else if (mode == 5) { t.x[v] = (int)(rnd() % 2) * 2047 - (int)(rnd() % 2) * 2048; t.y[v] = rrange(-2048, 2047); }
            else if (mode == 6) { t.x[v] = rrange(0, SW - 1); t.y[v] = 5 + (int)(rnd() % 3); }
            else { t.x[v] = rrange(0, SW - 1); t.y[v] = rrange(0, SH - 1); }
            for (int k = 0; k < 3; k++) t.c[v][k] = (int)(rnd() & 255);
        }
        if (mode == 7 && i % 16 == 7) { /* collinear */
            t.x[2] = 2 * t.x[1] - t.x[0]; t.y[2] = 2 * t.y[1] - t.y[0];
            if (t.x[2] > 2047 || t.x[2] < -2048 || t.y[2] > 2047 || t.y[2] < -2048) { t.x[2] = t.x[1]; t.y[2] = t.y[1]; }
        }
        print_tri(&t);
    }
}

/* Parallelograms, each split along both diagonals (4 triangles per group).
 * Both splits must cover exactly the same pixels, with no overlap inside a split. */
static void gen_quads(int n, uint64_t seed)
{
    rng_s = seed * 2654435761u + 7;
    for (int i = 0; i < n; i++) {
        int ux, uy, vx, vy;
        do {
            ux = rrange(-24, 24); uy = rrange(-24, 24);
            vx = rrange(-24, 24); vy = rrange(-24, 24);
        } while (ux * vy - uy * vx == 0);
        int px[4], py[4];
        px[0] = rrange(10, SW - 10); py[0] = rrange(10, SH - 10);
        px[1] = px[0] + ux;      py[1] = py[0] + uy;
        px[2] = px[0] + ux + vx; py[2] = py[0] + uy + vy;
        px[3] = px[0] + vx;      py[3] = py[0] + vy;
        int split[2][2][3] = {{{0, 1, 2}, {0, 2, 3}}, {{1, 2, 3}, {1, 3, 0}}};
        for (int s = 0; s < 2; s++)
            for (int h = 0; h < 2; h++) {
                tri_t t;
                for (int v = 0; v < 3; v++) {
                    int idx = split[s][h][v];
                    t.x[v] = px[idx]; t.y[v] = py[idx];
                    for (int k = 0; k < 3; k++) t.c[v][k] = 40 * (idx + 1) + 20 * k;
                }
                print_tri(&t);
            }
    }
}

static void emit_print(int x, int y, int r, int g, int b, void *u)
{
    printf("%d %d %d %02x%02x%02x\n", *(int *)u, x, y, r, g, b);
}

int main(int argc, char **argv)
{
    if (argc >= 3 && !strcmp(argv[1], "gen")) { gen(atoi(argv[2]), argc > 3 ? strtoull(argv[3], 0, 10) : 1); return 0; }
    if (argc >= 3 && !strcmp(argv[1], "quads")) { gen_quads(atoi(argv[2]), argc > 3 ? strtoull(argv[3], 0, 10) : 1); return 0; }
    if (argc >= 2 && !strcmp(argv[1], "run")) {
        tri_t t; int idx = 0;
        while (read_tri(stdin, &t)) { raster(t, emit_print, &idx); idx++; }
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "tiles")) {
        /* reads an RTL pixel log "tri cycle x y rgb"; triangles come in groups of
         * four (two splits of one quad) */
        static unsigned char cov[4][SH][SW];
        int tri, cyc, x, y; unsigned rgb;
        int groups = 0, overlaps = 0, mismatches = 0, cur = -1;
        char line[256];
        for (;;) {
            int got = fgets(line, sizeof line, stdin) && sscanf(line, "%d %d %d %d %x", &tri, &cyc, &x, &y, &rgb) == 5;
            if (!got || tri / 4 != cur) {
                if (cur >= 0) {
                    for (int j = 0; j < SH; j++) for (int i = 0; i < SW; i++) {
                        int a = cov[0][j][i] + cov[1][j][i], b = cov[2][j][i] + cov[3][j][i];
                        if (a > 1 || b > 1) overlaps++;
                        if ((a != 0) != (b != 0)) mismatches++;
                    }
                    groups++;
                }
                memset(cov, 0, sizeof cov);
                if (!got) break;
                cur = tri / 4;
            }
            cov[tri & 3][y][x]++;
        }
        printf("quads_with_pixels=%d overlap_pixels=%d diagonal_mismatch_pixels=%d\n", groups, overlaps, mismatches);
        return overlaps || mismatches;
    }
    fprintf(stderr, "usage: raster gen N [seed] | quads N [seed] | run < tris | tiles < log\n");
    return 2;
}
