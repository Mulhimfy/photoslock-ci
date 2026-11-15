# Prints "x y", the centre of the first square, clickable node under the header
# in a uiautomator dump: the first photo cell of a grid.
import re
import sys

x = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
for n in re.findall(r'<node [^>]*>', x):
    if 'clickable="true"' not in n:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if not b:
        continue
    x1, y1, x2, y2 = map(int, b.groups())
    w, h = x2 - x1, y2 - y1
    if y1 > 250 and w > 200 and abs(w - h) < 12:
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
