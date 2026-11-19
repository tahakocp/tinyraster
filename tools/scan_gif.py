"""Turns a pixel log into an animation of the scan order. Needs Pillow."""
import sys
from PIL import Image

W, H, STEP = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
src, dst = sys.argv[4], sys.argv[5]

img = Image.new("RGB", (W, H), (0, 0, 0))
px = img.load()
frames, n = [], 0
for line in open(src):
    _, _, x, y, rgb = line.split()
    px[int(x), int(y)] = tuple(int(rgb[i:i + 2], 16) for i in (0, 2, 4))
    n += 1
    if n % STEP == 0:
        frames.append(img.copy())
frames.append(img.copy())
frames[0].save(dst, save_all=True, append_images=frames[1:], duration=60, loop=0, optimize=True)
print(len(frames), "frames")
