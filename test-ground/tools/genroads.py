import xml.etree.ElementTree as ET, math, sys
SRC = "/mnt/user-data/uploads/ProjectZomboid/media/maps/Muldraugh, KY/streets.xml"
OUT = "/tmp/claude-0/-home-claude/91392442-91f3-5555-956d-ce09558093cb/scratchpad/work/test-ground/TestGround/42/media/lua/shared/TestGroundRoads.lua"
t = ET.parse(SRC)
streets = []
for s in t.getroot():
    n = s.get('name'); w = float(s.get('width'))
    pts = [(float(p.get('x')), float(p.get('y'))) for p in s.iter('point')]
    streets.append((n, w, pts))

def plen(pts): return sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))

# straight pieces (1.7.0)
rows = []
for n, w, pts in streets:
    if 'rail' in n.lower() or w < 5: continue
    for a, b in zip(pts, pts[1:]):
        if (a[0] == b[0] or a[1] == b[1]) and math.dist(a, b) >= 500:
            rows.append((n, int(w), int(a[0]), int(a[1]), int(b[0]), int(b[1])))
rows.sort(key=lambda r: (r[3], r[2]))

# routes (1.8.0): same-name polylines chained end to end (gap up to 150 tiles), simplified
def dp(pts, tol):
    if len(pts) < 3: return pts
    a, b = pts[0], pts[-1]
    L = math.dist(a, b) or 1e-9
    best, bi = -1, -1
    for i in range(1, len(pts) - 1):
        p = pts[i]
        d = abs((b[0]-a[0])*(a[1]-p[1]) - (a[0]-p[0])*(b[1]-a[1])) / L
        if d > best: best, bi = d, i
    if best <= tol: return [a, b]
    return dp(pts[:bi+1], tol)[:-1] + dp(pts[bi:], tol)

byname = {}
for n, w, pts in streets:
    if 'rail' in n.lower() or w < 6 or len(pts) < 2: continue
    byname.setdefault(n, []).append([w, list(pts)])
routes = []
GAP = 150
for n, parts in byname.items():
    parts = [p for p in parts]
    while parts:
        w, chain = parts.pop(0)
        grown = True
        while grown:
            grown = False
            for i, (w2, q) in enumerate(parts):
                for qq in (q, q[::-1]):
                    if math.dist(chain[-1], qq[0]) <= GAP:
                        chain = chain + (qq[1:] if math.dist(chain[-1], qq[0]) < 1 else qq); w = max(w, w2); parts.pop(i); grown = True; break
                    if math.dist(chain[0], qq[-1]) <= GAP:
                        chain = (qq[:-1] if math.dist(chain[0], qq[-1]) < 1 else qq) + chain; w = max(w, w2); parts.pop(i); grown = True; break
                if grown: break
        if plen(chain) >= 1500:
            s = dp(chain, 2.0)
            s = [(int(round(x)), int(round(y))) for x, y in s]
            ded = [s[0]] + [p for a, p in zip(s, s[1:]) if p != a]
            routes.append((n, int(w), ded, plen(chain)))
routes.sort(key=lambda r: (r[2][0][1], r[2][0][0]))

out = ["-- Streets of the vanilla map (Muldraugh, KY), for Test Ground's drivefast step. Generated from",
       "-- the game's media/maps/Muldraugh, KY/streets.xml (street centre lines with widths).",
       "--",
       "-- TestGroundRoads: every axis-aligned straight piece of 500+ tiles on a street 5+ tiles wide,",
       "-- railroads left out. { name, width, x1, y1, x2, y2 }.",
       "TestGroundRoads = {"]
for r in rows:
    out.append('\t{ "%s", %d, %d, %d, %d, %d },' % ((r[0].replace('"', '\\"'),) + r[1:]))
out.append("}")
out += ["",
        "-- TestGroundRoutes: whole streets 6+ wide and 1500+ tiles long, pieces with the same name joined",
        "-- end to end (gaps up to 150 tiles), simplified to corners (2-tile tolerance). { name, width, { x1, y1, x2, y2, ... } }.",
        "TestGroundRoutes = {"]
for n, w, pts, L in routes:
    flat = ", ".join("%d, %d" % p for p in pts)
    out.append('\t{ "%s", %d, { %s } },   -- %d tiles' % (n.replace('"', '\\"'), w, flat, L))
out.append("}")
open(OUT, "w").write("\n".join(out) + "\n")
print(len(rows), "roads,", len(routes), "routes")
for n, w, pts, L in routes:
    if "Dixie" in n or "Main St" == n: print(n, w, len(pts), int(L), pts[0], pts[-1])
