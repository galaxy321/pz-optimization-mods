# Rural road pieces for Test Ground's tree-lined drive: straight street pieces of 150+ tiles, 5 to 9
# wide, with no building within 40 tiles of any point (from worldmap.xml), so likely through woods.
import re, math, pickle, sys
blds = pickle.load(open('blds.pkl', 'rb'))
src = open("/mnt/user-data/uploads/ProjectZomboid/media/maps/Muldraugh, KY/streets.xml").read()
grid = {}
for t, x, y in blds:
    grid.setdefault((int(x // 50), int(y // 50)), []).append((x, y))
def nearB(x, y, r):
    gx, gy = int(x // 50), int(y // 50)
    for i in range(gx - 1, gx + 2):
        for j in range(gy - 1, gy + 2):
            for bx, by in grid.get((i, j), []):
                if (bx - x) ** 2 + (by - y) ** 2 < r * r: return True
    return False
out = []
for m in re.finditer(r'<street name="([^"]*)" width="([\d.]+)">(.*?)</street>', src, re.S):
    name, w = m.group(1), float(m.group(2))
    if not (5 <= w <= 9) or 'Rail' in name: continue
    pts = [(float(a), float(b)) for a, b in re.findall(r'x="([\d.]+)" y="([\d.]+)"', m.group(3))]
    for a, b in zip(pts, pts[1:]):
        L = math.dist(a, b)
        if L < 150: continue
        # walk 150-tile windows along the piece, keep the first clear one (and every 600 tiles)
        n = int(L // 10)
        k = 0
        while k * 10 + 150 <= L:
            s0 = k * 10
            ok = True
            for s in range(s0, s0 + 151, 10):
                f = s / L
                x, y = a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f
                if nearB(x, y, 40): ok = False; break
            if ok:
                f0, f1 = s0 / L, (s0 + 150) / L
                out.append((name, int(w), round(a[0] + (b[0] - a[0]) * f0), round(a[1] + (b[1] - a[1]) * f0),
                            round(a[0] + (b[0] - a[0]) * f1), round(a[1] + (b[1] - a[1]) * f1)))
                k += 60
            else:
                k += 1
print(len(out), file=sys.stderr)
lines = ["", "-- TestGroundTreeRoads: 150-tile straight pieces of streets 5 to 9 wide with no building within 40",
         "-- tiles (worldmap.xml), so most likely through woods; the treeroad step counts the trees there",
         "-- in game. { name, width, x1, y1, x2, y2 }. Made by gentrees.py.", "TestGroundTreeRoads = {"]
for o in out:
    lines.append('\t{ "%s", %d, %d, %d, %d, %d },' % o)
lines.append("}")
print("\n".join(lines))
wp = (11501, 6949)
near = sorted(out, key=lambda o: math.dist(wp, ((o[2]+o[4])/2, (o[3]+o[5])/2)))[:6]
for o in near: print(o, round(math.dist(wp, ((o[2]+o[4])/2, (o[3]+o[5])/2))), file=sys.stderr)
