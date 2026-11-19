# Architecture

## Method

For each edge a to b of a triangle, `E(p) = (bx-ax)*(py-ay) - (by-ay)*(px-ax)`. Three edge values per pixel, all positive inside. They sum to the triangle's area, which is also what the colour divides by.

The RTL never multiplies per pixel. `E` is evaluated once at the first pixel of the clipped bounding box and then stepped: add `-(by-ay)` per pixel in x, add `(bx-ax)` per row.

## Setup

A fixed sequence, about 200 clocks:

1. Compute twice the signed area. Zero: finish with no pixels. Negative: swap v1 and v2 so every triangle has the same winding.
2. Bounding box, clipped to the screen. Empty: finish.
3. Edge steps and top-left flags.
4. Six products for the edge values at the box origin, then 27 products for the colour numerators and their x and y steps. One 32x13 multiplier does all 33, one per clock. Fully parallel setup was 23k iCE40 LUT4; this is 6.4k.
5. Nine divisions by the area, three at a time (one divider per colour channel): origin value, x gradient, y gradient. Each is 52 clocks.

## Fill rule

A pixel on an edge belongs to the triangle only if the edge is a top or left edge. With positive winding and y growing downwards: an edge is "left" when `dy < 0`, and "top" when `dy == 0 && dx > 0`. Because the two triangles sharing an edge traverse it in opposite directions, exactly one of them owns the pixels on it. That is what the quads test exercises.

## Colour

For channel k, the numerator `N(p) = c0*w0 + c1*w1 + c2*w2` is linear in p, so it also steps. The divided value is kept in Q16: the origin value and the two gradients are `trunc(N * 65536 / area)`, and the scan adds the gradient per pixel and per row. Output is `clamp((q + 32768) >> 16, 0, 255)`.

Truncating the gradients means error builds up along a row, at most one Q16 unit per pixel. Across a 320-pixel row that is about 0.005 of an 8-bit level, which is below rounding. The model does exactly the same accumulation, which is why the comparison is exact and not "close enough".

## Why the accumulators wrap

The accumulators are 40 bits. For a very thin triangle with a far-away bounding-box corner, the origin value can be far outside 40 bits. Modular arithmetic does not care: the pixels that get drawn are inside the triangle, where the true value is within 0..255 in Q16, and a sum that is correct modulo 2^40 reads back correctly. The extreme-coordinate triangles in the random test (mode 3 and 5 in `model/raster.c`) are there for this.

## Widths

12-bit coordinates give differences of 13 bits and edge values below 2^25. Colour numerators are below 2^35 and after the shift by 16 below 2^51, hence the 52-bit divider.
