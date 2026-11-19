# Contributing

Most useful: a triangle where the RTL and `model/raster.c` disagree, or where the picture is plainly wrong. Put the line from a `scenes/*.txt` file in an issue.

For changes:

```
make test
make synth
```

Both must pass, and the numbers in the README should still be true. If you change the arithmetic, change `model/raster.c` in the same commit, since the tests compare the two.

Style: no tabs, `logic` over `reg`/`wire` where it reads better, comments that say why.
