"""校验全部功能图标的资源一致性、拓扑、等宽偏移与反白孔；不改写文件。"""
import runpy
from pathlib import Path
from ink.geometry import G, WEIGHTS, Arc, _offset, area, dist, sample, stroke
from ink.rounded import BUILDERS, centerlines
from ink.rounded.shared import WIDTH, closed_stroke

ROOT = Path(__file__).resolve().parents[2]
g = runpy.run_path(str(ROOT / "design/tools/cue-symbols.py"))

def verify_cutouts(name,layers):
    """反白底的可见结果必须等于底减去白区并集，不能在孔相交处重新填黑。"""
    def polygon(contour):
        return [sample(s,k/n) for s in contour for n in [12 if isinstance(s,Arc) else 1] for k in range(n)]
    def winding(points,x,y):
        result = 0
        for a,b in zip(points,points[1:]+points[:1]):
            cross = (b[0]-a[0])*(y-a[1])-(x-a[0])*(b[1]-a[1])
            if a[1] <= y < b[1] and cross > 0: result += 1
            elif b[1] <= y < a[1] and cross < 0: result -= 1
        return result
    for layer in layers:
        if layer.name != "badge": continue
        outer,*holes = map(polygon,layer.contours)
        assert area(layer.contours[0])>0 and all(area(c)<0 for c in layer.contours[1:]),name
        for ix in range(-48,49):
            for iy in range(-48,49):
                x,y = (ix+.17)*G/4,(iy+.31)*G/4
                base_winding = winding(outer,x,y)
                cutouts = [winding(h,x,y) for h in holes]
                expected = bool(base_winding) and not any(cutouts)
                actual = bool(base_winding+sum(cutouts))
                assert actual == expected, f"{name}: cutout union refills at ({x/G:.2f},{y/G:.2f})"


def verify():
    """覆盖、母版拓扑、中线/圆角/闭合接缝与精确法向偏移；不试装资源。"""
    for path, content in g["generate"]().items():
        assert path.read_text(encoding="utf-8") == content, f"Generated file differs: {path.relative_to(ROOT)}"
    samples,maximum = 0,0.0
    for name in BUILDERS:
        try:
            for weight in WEIGHTS:
                verify_cutouts(name, g["SYMBOLS"][name](weight))
            for closed,paths in enumerate(centerlines(name)):
                for path in paths:
                    for a,b in zip(path,path[1:]+(path[:1] if closed else [])):
                        assert dist(a.end(),b.start()) < 1e-7,"Disconnected centerline"
                        if isinstance(a,Arc) or isinstance(b,Arc):
                            assert sum(x*y for x,y in zip(a.dir1(),b.dir0())) > 1-1e-7,"Non-tangent corner or overshoot"
                    for w in WIDTH.values():
                        h = w*G/2
                        for segment in path:
                            for sign in (-1,1):
                                offset = _offset(segment,sign*h)
                                for t in (0,.25,.5,.75,1):
                                    error = abs(dist(sample(segment,t),sample(offset,t))-h)
                                    maximum = max(maximum,error); samples += 1
                                    assert error < 1e-9,"Nonuniform offset"
                        shapes = closed_stroke(path,w) if closed else [stroke(path,w*G)]
                        for contour in shapes:
                            for a,b in zip(contour,contour[1:]+contour[:1]):
                                assert dist(a.end(),b.start()) < 1e-7,"Disconnected outline"
        except Exception as error:
            raise AssertionError(f"{name}: {error}") from error
    print(f"Verified {len(BUILDERS)} symbols × {len(WEIGHTS)} masters; {samples} normal-offset samples; max error {maximum:.3g}; generated files match source")



if __name__ == "__main__":
    verify()
