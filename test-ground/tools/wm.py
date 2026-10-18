import re,sys,math
src=open("/mnt/user-data/uploads/ProjectZomboid/media/maps/Muldraugh, KY/worldmap.xml").read()
blds=[]
for cm in re.finditer(r'<cell x="(\d+)" y="(\d+)">(.*?)</cell>',src,re.S):
    cx,cy=int(cm.group(1))*300,int(cm.group(2))*300
    for f in re.finditer(r'<feature>(.*?)</feature>',cm.group(3),re.S):
        b=re.search(r'name="building" value="(\w+)"',f.group(1))
        if not b: continue
        pts=[(cx+int(a),cy+int(c)) for a,c in re.findall(r'<point x="(-?\d+)" y="(-?\d+)"/>',f.group(1))]
        x=sum(p[0] for p in pts)/len(pts); y=sum(p[1] for p in pts)/len(pts)
        blds.append((b.group(1),x,y))
import pickle; pickle.dump(blds,open('blds.pkl','wb'))
print(len(blds))
