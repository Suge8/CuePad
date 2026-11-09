"""功能图标：动作、文件、设备；中线与基准族共用。"""
from ink.geometry import arcs, disc, poly, rpoly
from . import base
from .shared import box, moved

NAMES = (
    "settings", "sidebar.right", "clear", "chevron.up", "chevron.right", "chevron.down", "chevron.left",
    "done.pre", "reopen", "restore", "indent", "outdent", "link", "unlink", "folder.remove", "pin", "unpin",
    "conflict", "deck", "share", "save", "pencil", "write", "choose", "puzzle", "tick", "plane.done",
    "arrow.up", "arrow.down", "ring.down", "ring.stop", "ring.play", "ring.plus", "badge.down", "compact",
    "hand", "mac", "photo", "photos", "select", "keyboard.down", "braces", "window", "doc.blank", "wrench",
    "branch", "flame", "eye", "power", "mail", "tag", "keyboard", "sun", "wave", "bubble.text", "bubble.dots",
    "mic", "mic.off",
)


def centerlines(name):
    opened, closed = [], []
    def line(*points, radius=0): opened.append(poly(points,radius))
    def circle(x,y,r): closed.append(arcs((x,y),r,-90,360))
    def rectangle(x,y,a,b,r=3): closed.append(box(x,y,a,b,r))
    def arrow(down=False, x=0, y=0, size=7):
        s = 1 if down else -1
        line((x,y-s*size),(x,y+s*size))
        line((x-size*.65,y+s*size*.35),(x,y+s*size),(x+size*.65,y+s*size*.35))
    if name == "settings":
        for x,y in ((-7,3),(0,-3),(7,1)):
            line((x,-10),(x,y-3)); line((x,y+3),(x,10)); circle(x,y,3)
    elif name == "sidebar.right":
        opened,closed = base.centerlines("sidebar")
        opened = [moved(p,angle=180) for p in opened]
    elif name.startswith("chevron."):
        degrees = {"up":0,"right":90,"down":180,"left":270}[name.split(".")[1]]
        opened.append(moved(poly([(-6,3),(0,-3),(6,3)]),angle=degrees))
    elif name == "clear":
        closed.append(poly([(-11,0),(-5,-7),(10,-7),(10,7),(-5,7)],[1.8,1.8,2.5,2.5,1.8],True))
        line((-1,-3),(5,3)); line((5,-3),(-1,3))
    elif name == "done.pre":
        circle(0,0,10)
    elif name in ("reopen","restore"):
        opened.append(arcs((0,1),8,-150,285))
        line((-8,-7),(-8,-2),(-3,-2))
        if name == "restore": line((0,-3),(0,1),(4,1))
    elif name in ("indent","outdent"):
        for y in (-8,0,8): line((1,y),(10,y))
        direction = 1 if name == "indent" else -1
        opened.append(moved(poly([(-2,-4),(2,0),(-2,4)]),x=-7,angle=0 if direction==1 else 180))
    elif name in ("link","unlink"):
        # 两枚开口链环，断开态缩短两端并以两道短划明确断裂。
        if name == "link":
            opened.append(moved(arcs((0,0),4.5,90,270)+poly([(4.5,0),(4.5,4)]),x=-3,y=3,angle=45))
            opened.append(moved(arcs((0,0),4.5,90,270)+poly([(4.5,0),(4.5,4)]),x=3,y=-3,angle=225))
            line((-3,3),(3,-3))
        else:
            opened.append(moved(arcs((0,0),4.5,30,270),x=-5,y=5))
            opened.append(moved(arcs((0,0),4.5,210,270),x=5,y=-5))
            line((-6,-5),(-3,-2)); line((3,2),(6,5))
    elif name == "folder.remove":
        opened,closed = base.centerlines("folder"); line((-3,3),(3,3))
    elif name in ("pin","unpin"):
        line((-4,-9),(4,-9)); line((-3,-9),(-3,-3),(-7,2),(7,2),(3,-3),(3,-9),radius=1.6)
        line((0,2),(0,10))
        if name == "unpin": line((-10,-10),(10,10))
    elif name == "conflict":
        rectangle(-10,-9,3,5,2.5); rectangle(-3,-4,10,10,2.5)
    elif name == "deck":
        rectangle(-9,-2,9,10,2.5); line((-8,-6),(8,-6)); line((-5,-10),(5,-10))
    elif name in ("share","save"):
        line((-9,1),(-9,9),(9,9),(9,1),radius=2.5)
        arrow(name=="save",y=-3,size=6)
    elif name in ("pencil","write"):
        closed.append(poly([(-9,9),(-7,3),(5,-9),(10,-4),(-2,8)],[1.6,1.6,1.6,1.6,1.6],True))
        line((2,-6),(7,-1))
        if name == "write": line((-7,12),(9,12))
    elif name == "choose":
        line((-6,-4),(0,-10),(6,-4)); line((-6,4),(0,10),(6,4))
    elif name == "puzzle":
        closed.append(poly([(-9,-9),(-2,-9),(-2,-13),(3,-13),(3,-9),(9,-9),
                            (9,-2),(13,-2),(13,3),(9,3),(9,9),(-9,9)],1.6,True))
    elif name == "tick": opened,closed = base.centerlines("done")
    elif name == "plane.done":
        opened,closed = base.centerlines("plane"); line((5,9),(8,12),(13,6))
    elif name in ("arrow.up","arrow.down"): arrow(name.endswith("down"),size=9)
    elif name.startswith("ring.") or name == "badge.down":
        circle(0,0,10)
        mark = name.split(".")[-1]
        if mark == "down": arrow(True,size=5)
        elif mark == "plus": line((-4,0),(4,0)); line((0,-4),(0,4))
    elif name == "compact":
        line((-9,-9),(-2,-2)); line((-7,-2),(-2,-2),(-2,-7))
        line((9,9),(2,2)); line((7,2),(2,2),(2,7))
    elif name == "hand":
        # 指尖合成圆润上缘，以两条指缝分组；拇指与掌底保留可辨的外轮廓。
        closed.append(poly([(-4,10),(-10,3),(-10,0),(-8,-3),(-4,4),(-4,-7),(-1,-10),(3,-10),(7,-7),(7,4),(3,10)],
                           [3,2,1.6,1.6,0,2,2,2,2.5,3,3],True))
        line((0,-6),(0,0)); line((3.5,-5),(3.5,0))
    elif name == "mac":
        rectangle(-10,-8,10,6,2.5); line((-4,10),(4,10)); line((0,6),(0,10))
    elif name in ("photo","photos"):
        rectangle(-8,-7,10,9,2.5)
        line((-8,5),(-2,-1),(3,4),(6,1),(10,5),radius=1.6)
        if name == "photos": line((4,-11),(-11,-11),(-11,4),radius=2.5)
    elif name == "select":
        line((-8,-9),(-3,-9)); line((-5.5,-9),(-5.5,9)); line((-8,9),(-3,9))
        line((3,-9),(8,-9)); line((5.5,-9),(5.5,9)); line((3,9),(8,9))
        line((-1,0),(1,0))
    elif name in ("keyboard","keyboard.down"):
        rectangle(-11,-7,11,7,2.5)
        for x in (-6,0,6): line((x,-2),(x,-1))
        line((-5,3),(5,3))
        if name == "keyboard.down": line((-4,11),(0,14),(4,11))
    elif name == "braces":
        for sign in (-1,1):
            opened.append(poly([(sign*8,-10),(sign*4,-10),(sign*4,-3),(sign,0),(sign*4,3),(sign*4,10),(sign*8,10)],1.6))
    elif name == "window":
        rectangle(-10,-9,10,9,3); line((-10,-3),(10,-3))
    elif name == "doc.blank":
        _,closed = base.centerlines("doc")
    elif name == "wrench":
        closed.append(poly([(-8,10),(-11,7),(0,-4),(0,-9),(5,-11),(3,-6),(6,-3),(11,-5),(9,0),(4,0)],
                           [1.8,1.8,1.8,2,0,0,0,0,2,1.8],True))
    elif name == "branch":
        line((-6,-5),(-6,6)); line((-6,2),(6,-4),radius=2)
        circle(-6,-8,2.5); circle(-6,9,2.5); circle(7,-7,2.5)
    elif name == "flame":
        closed.append(poly([(0,-11),(7,-3),(8,5),(3,10),(-4,10),(-10,4),(-9,-6),(-3,1)],[1.7,3,3,3,3,3,1.7,1.7],True))
        line((-2,6),(0,2),(3,6),radius=1.6)
    elif name == "eye":
        closed.append(poly([(-12,0),(0,-8),(12,0),(0,8)],3,True))
        circle(0,0,3)
    elif name == "power":
        opened.append(arcs((0,1),8,-45,270)); line((0,-10),(0,0))
    elif name == "mail":
        rectangle(-10,-7,10,8,3); line((-9,-5),(0,2),(9,-5),radius=1.6)
    elif name == "tag":
        closed.append(poly([(-10,-9),(0,-9),(10,1),(1,10),(-10,0)],2,True)); circle(-5,-4,2)
    elif name == "sun":
        circle(0,0,5)
        for degree in range(0,360,45): opened.append(moved(poly([(0,-9),(0,-11)]),angle=degree))
    elif name == "wave":
        for x,height in ((-10,2),(-5,5),(0,9),(5,6),(10,3)): line((x,-height),(x,height))
    elif name in ("mic","mic.off"):
        # 收音胶囊、托架与底座；关掉时同 bell.off 斜划一道。
        closed.append(arcs((0,-7),4,180,180)+poly([(4,-7),(4,-1)],0)+arcs((0,-1),4,0,180)+poly([(-4,-1),(-4,-7)],0))
        opened.append(arcs((0,-2),7.5,0,180))
        line((0,5.5),(0,10)); line((-4,10),(4,10))
        if name == "mic.off": line((-10,-10),(10,10))
    elif name in ("bubble.text","bubble.dots"):
        _,closed = base.centerlines("bubble")
        if name == "bubble.text": line((-4,-3),(4,-3)); line((-4,2),(2,2))
    else: raise ValueError(name)
    return opened,closed


def fills(name,w):
    if name == "bubble.dots": return [disc((x,-1),w*.5) for x in (-5,0,5)]
    if name in ("photo","photos"): return [disc((4,-2),w*.6)]
    if name == "ring.stop": return [rpoly([(-3,-3),(3,-3),(3,3),(-3,3)],[1.6]*4)]
    if name == "ring.play": return [rpoly([(-3,-5),(5,0),(-3,5)],[1]*3)]
    return []
