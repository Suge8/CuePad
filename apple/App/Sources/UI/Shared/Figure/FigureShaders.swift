/// Cue 角色的着色器源码：App 运行时交给系统编（`FigureGPU.warm`），不进构建——项目不另装 Metal 编译工具链（本机与 CI 都省一份依赖）。
/// 与 `FigureUniforms`、`FigureSprite` 逐字段对齐。
nonisolated enum FigureShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// 全是 float4 / float3x3：与 Swift 那边的 SIMD 类型布局一样。
struct Uniforms {
    float3x3 body;   // 世界 → 身子：先俯仰再转身
    float3x3 ring;   // 世界 → 环
    float4 a;        // lift, off, floor, squash
    float4 b;        // ringAngle, blink, squint, time
    float4 c;        // lookX, lookY, hand, minis
    float4 d;        // miniAngle, pulse, flash, light（0 深色，1 浅色）
    float4 e;        // N, span, life（0 在，1 拼起，2 碎开）, lifeAge
    float4 f;        // 视图宽, 高, 格子边长（点）, 第几遍（0 底光 / 投影，1 格子）
    float4 g;        // 角色左上角 x, y（点）, 0, 0
    float4 sh, mid, lit, tint, rim, dark, eye, cheek, line, r1, r2, r3, hl, pool, acc;
};

struct Tile { float4 col; float4 ext; };   // rgb + 覆盖；发光, 手, 环, 0
struct Sprite { float4 rect; float4 col; }; // x, y, 边长, 透明；rgb, 发光

enum { BODY, FOLD, FEET, HAND, RING, MINI };

struct Hit { float d; int id; float3 q; float3 p; };

static float sdBox(float3 p, float3 b, float r) {
    float3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}
static float capsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}
static float hash3(int x, int y, int z) {
    uint h = uint(x) * 374761393u ^ uint(y) * 668265263u ^ uint(z) * 1440662683u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return float(h ^ (h >> 16)) / 4294967295.0;
}

static float3 toBody(float3 w, constant Uniforms &u) {
    float3 q = float3(w.x, w.y - u.a.x + u.a.y, w.z);
    float sq = u.a.w, fl = u.a.z;
    q = float3(q.x / (1 + sq * 0.6), (q.y - fl) / (1 - sq) + fl, q.z);
    return u.body * q;
}

static Hit minis(float3 w, constant Uniforms &u, Hit h) {
    float k = clamp(u.c.w, 0.0, 1.25);
    if (k < 0.05) return h;
    float lift = u.a.x - u.a.y + 0.05;
    for (int i = 0; i < 2; i++) {
        float a = u.d.x + float(i) * M_PI_F;
        float3 c = float3(cos(a) * 1.1 * k, lift + sin(a * 2) * 0.06, sin(a) * 0.55);
        float3 m = (w - c) / k;
        float d = sdBox(m, float3(0.15, 0.13, 0.12), 0.06) * k;
        if (d < h.d) h = Hit{d, MINI, m, h.p};
    }
    return h;
}

static Hit scene(float3 w, constant Uniforms &u) {
    float3 p = toBody(w, u);
    float body = sdBox(p, float3(0.56, 0.7, 0.48), 0.22), fold = (p.x + p.y - 0.98) / M_SQRT2_F;
    Hit h = Hit{max(body, fold), fold > body - 0.002 ? FOLD : BODY, float3(0), p};
    float feet = min(sdBox(p + float3(0.26, 0.8, 0), float3(0.13, 0.1, 0.16), 0.08), sdBox(p + float3(-0.26, 0.8, 0), float3(0.13, 0.1, 0.16), 0.08));
    if (feet < h.d) { h.d = feet; h.id = FEET; }
    if (u.c.z > 0.03) {   // 托腮：手肘伸到身子外面，手绕到脸前
        float k = min(u.c.z, 1.25), tap = sin(u.b.w * 5) * 0.03 * k;
        float3 sh = float3(-0.48, -0.16, -0.02), el = float3(-0.5 - 0.36 * k, -0.16 - 0.06 * k, -0.04 - 0.26 * k);
        float3 hd = float3(-0.5 + 0.22 * k, -0.16 + 0.14 * k + tap, -0.04 - 0.6 * k);
        float d = min(min(capsule(p, sh, el, 0.075), capsule(p, el, hd, 0.07)), length(p - hd) - 0.125);
        if (d < h.d) { h.d = d; h.id = HAND; }
    }
    float3 r = u.ring * float3(w.x, w.y - u.a.x + 0.28, w.z);
    float tor = length(float2(length(r.xy) - 1.08, r.z)) - 0.078;
    if (tor < h.d) { h.d = tor; h.id = RING; h.q = r; }
    return minis(w, u, h);
}

static float3 normalAt(float3 w, constant Uniforms &u) {
    const float e = 0.004;
    const float3 k0 = float3(1, -1, -1), k1 = float3(-1, -1, 1), k2 = float3(-1, 1, -1), k3 = float3(1, 1, 1);
    return normalize(k0 * scene(w + k0 * e, u).d + k1 * scene(w + k1 * e, u).d + k2 * scene(w + k2 * e, u).d + k3 * scene(w + k3 * e, u).d);
}

static float3 ramp(constant Uniforms &u, float l) {
    float x = clamp((l - 0.3) / 0.8, 0.0, 1.0);
    return x < 0.5 ? mix(u.sh.rgb, u.mid.rgb, x * 2) : mix(u.mid.rgb, u.lit.rgb, (x - 0.5) * 2);
}

struct Shade { float3 col; float glow; };

static Shade shade(float3 w, Hit h, constant Uniforms &u) {
    const float3 L = normalize(float3(-0.45, 0.58, -0.72));
    float amb = u.d.w > 0.5 ? 0.52 : 0.4;
    float3 n = normalAt(w, u), p = h.p;
    float dif = max(0.0, dot(n, L)), l = amb + dif * 0.75;
    float blink = u.b.y, squint = u.b.z;
    float3 skin = mix(ramp(u, l), u.rim.rgb, pow(1 - abs(n.z), 2.5) * smoothstep(-0.1, 0.5, n.x) * 0.65);
    Shade o = Shade{skin, 0};
    if (h.id == RING) {
        float ang = atan2(h.q.y, h.q.x), hp = 0.5 + 0.5 * cos(ang - u.b.x * 0.35);
        float3 base = hp < 0.5 ? mix(u.r1.rgb, u.r2.rgb, hp * 2) : mix(u.r2.rgb, u.r3.rgb, (hp - 0.5) * 2);
        float hl = pow(max(0.0, cos(ang - u.b.x)), 16.0);
        o.col = mix(mix(base, u.acc.rgb, 0.3) * (0.7 + clamp(amb + dif * 0.7, 0.0, 1.1) * 0.4), u.hl.rgb, clamp(hl * 0.9 + u.d.y * 0.45 + u.d.z * 0.5, 0.0, 1.0));
        o.glow = 0.4 + hl + u.d.y * 0.6 + u.d.z * 0.6;
    } else if (h.id == MINI) {
        float3 q = h.q;
        if (q.z < -0.1 && abs(q.y - 0.03) < 0.045 && abs(abs(q.x) - 0.06) < 0.025) o.col = u.eye.rgb;
    } else if (h.id == FOLD) {
        o.col = mix(u.dark.rgb, ramp(u, l), 0.14);
    } else {
        o.col = mix(skin, u.tint.rgb, exp(-pow((p.y + 0.2) / 0.24, 2.0)) * 0.3);   // 环映在腰上
        if (h.id == FEET) o.col *= 0.88;
        if (h.id == HAND) o.col *= 0.94;
        if (h.id == BODY && p.z < -0.4) {
            float ex = u.c.x * 0.08, ey = u.c.y * 0.06, eh = 0.15 * blink * (1 - squint * 0.6);
            for (int i = 0; i < 2; i++) {
                float ox = i == 0 ? -0.21 : 0.19;
                float cx = (p.x - ox * 1.3) / 0.1, cy = (p.y + 0.05) / 0.05;
                if (cx * cx + cy * cy < 1) o.col = mix(o.col, u.cheek.rgb, 0.45);
                float dx = (p.x - ox - ex) / 0.085, dy = (p.y - 0.16 - ey) / eh;
                if (dx * dx + dy * dy < 1) {
                    o.col = u.eye.rgb;
                    if (blink > 0.5 && (dx + 0.3) * (dx + 0.3) + (dy - 0.42) * (dy - 0.42) < 0.13) o.col = float3(1);
                }
            }
        }
    }
    return o;
}

/// 每格四个子采样各打一条光线：覆盖率给出边缘的半透明，颜色取平均。
kernel void figureTiles(constant Uniforms &u [[buffer(0)]], device Tile *tiles [[buffer(1)]], uint2 id [[thread_position_in_grid]]) {
    int n = int(u.e.x);
    if (int(id.x) >= n || int(id.y) >= n) return;
    float span = u.e.y, c = float(id.x), r = float(id.y);
    float lift = u.a.x, off = u.a.y;
    float uc = ((c + 0.5) / n - 0.5) * span, by = -((r + 0.5) / n - 0.5) * span - 0.06 - lift + off;
    float wide = u.c.w > 0.02 ? 1.4 : 1.28;
    Tile t = Tile{float4(0), float4(0)};
    if (abs(uc) <= wide && by >= u.a.z - 0.2 && by <= 1.08) {
        float3 acc = 0; float glow = 0, hand = 0, ring = 0, hits = 0;
        for (int i = 0; i < 4; i++) {
            float sx = (i & 1) ? 0.7 : 0.3, sy = (i & 2) ? 0.7 : 0.3;
            float uu = ((c + sx) / n - 0.5) * span, vv = -((r + sy) / n - 0.5) * span - 0.06, s = 0;
            for (int k = 0; k < 44; k++) {
                float3 w = float3(uu, vv, -1.6 + s);
                Hit h = scene(w, u);
                if (h.d < 0.002) {
                    Shade o = shade(w, h, u);
                    acc += o.col; glow += o.glow; hits += 1;
                    hand += h.id == HAND ? 1 : 0; ring += h.id == RING ? 1 : 0;
                    break;
                }
                s += h.d;
                if (s > 3.2) break;
            }
        }
        if (hits > 0) t = Tile{float4(acc / hits, hits / 4), float4(glow / hits, hand * 2 > hits ? 1 : 0, ring * 2 > hits ? 1 : 0, 0)};
    }
    tiles[id.y * uint(n) + id.x] = t;
}

struct Dot { float4 position [[position]]; float2 local; float4 col; float soft; };

static float4 corner(uint vid, float2 center, float size, constant Uniforms &u, thread float2 &local) {
    float2 k = float2((vid & 1) ? 1 : -1, (vid & 2) ? 1 : -1);
    local = k;
    float2 pt = center + k * size * 0.5;
    return float4(pt.x / u.f.x * 2 - 1, 1 - pt.y / u.f.y * 2, 0, 1);
}

static Dot hidden() { return Dot{float4(-9, -9, 0, 1), float2(0), float4(0), 0}; }

static float covAt(device const Tile *tiles, int n, int r, int c) { return (r < 0 || c < 0 || r >= n || c >= n) ? 0.0 : tiles[r * n + c].col.a; }
static float handAt(device const Tile *tiles, int n, int r, int c) { return (r < 0 || c < 0 || r >= n || c >= n) ? 0.0 : tiles[r * n + c].ext.y; }

/// 格子：浅色描边、手的描边、零星一闪，以及拼起 / 碎开时每格各自的飞行。第 0 遍画底光（深色）或投影（浅色），第 1 遍画格子。
vertex Dot tileVertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms &u [[buffer(0)]], device const Tile *tiles [[buffer(1)]]) {
    int n = int(u.e.x), c = int(iid) % n, r = int(iid) / n;
    Tile t = tiles[iid];
    float cov = t.col.a;
    if (cov <= 0) return hidden();
    bool light = u.d.w > 0.5, pass0 = u.f.w < 0.5;
    bool edge = covAt(tiles, n, r - 1, c) < 0.3 || covAt(tiles, n, r + 1, c) < 0.3 || covAt(tiles, n, r, c - 1) < 0.3 || covAt(tiles, n, r, c + 1) < 0.3;
    float3 col = t.col.rgb;
    if (light && edge && t.ext.z < 0.5) col = mix(col, u.line.rgb, 0.9);
    if (t.ext.y > 0.5) {
        bool touches = edge || handAt(tiles, n, r - 1, c) < 0.5 || handAt(tiles, n, r + 1, c) < 0.5 || handAt(tiles, n, r, c - 1) < 0.5 || handAt(tiles, n, r, c + 1) < 0.5;
        if (touches) col = mix(col, light ? u.line.rgb : u.sh.rgb, light ? 0.8 : 0.6);
    }
    float h1 = hash3(c, r, 11), h2 = hash3(c, r, 12), age = u.e.w, tile = u.f.z;
    if (t.ext.x > 0.5 && hash3(c, r, int(floor(u.b.w * 3 + h1 * 7))) < 0.01) col = float3(1);
    col *= 1 + (h2 - 0.5) * 0.06;
    float2 pos = float2(u.g.x + (c + 0.5) * tile, u.g.y + (r + 0.5) * tile);
    float size = tile, alpha = cov;
    float scale = tile / 3.4;   // 飞行距离按原型里 3.4 点一格量的，换了格子大小照比例
    if (u.e.z > 0.5 && u.e.z < 1.5) {   // 拼起：从下面飞上来，下面的先到
        float d = 0.42 * (1 - float(r) / n) + h1 * 0.16, k = smoothstep(d, d + 0.45, age / 0.95), m = (1 - k) * (1 - k);
        pos += float2((h1 - 0.5) * 50, 26 + h2 * 36) * m * scale; alpha *= k; size *= 0.45 + 0.55 * k;
    } else if (u.e.z > 1.5) {           // 碎开：往右上飘散，右边的先走
        float d = 0.3 * (1 - float(c) / n) + h2 * 0.14, k = smoothstep(d, d + 0.36, age / 0.6), m = k * k;
        pos += float2(36 + h1 * 60, -(6 + h2 * 40)) * m * scale; alpha *= 1 - k; size *= 1 - 0.45 * k;
    }
    Dot o;
    if (pass0) {
        if (light) { pos += float2(1, 4); size *= 1.25 * 2.2; o.col = float4(u.line.rgb, 0.42 * alpha); }
        else { if (t.ext.x <= 0) return hidden(); size *= 1.3 * 2.6; o.col = float4(col, min(1.0, t.ext.x * 0.55) * alpha); }
        o.soft = 1;
    } else { o.col = float4(col, alpha); o.soft = 0; }
    o.position = corner(vid, pos, size, u, o.local);
    return o;
}

/// 脚下的光、波纹、火星、念头：CPU 每帧给一串，与格子同一种点。
vertex Dot spriteVertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms &u [[buffer(0)]], device const Sprite *sprites [[buffer(1)]]) {
    Sprite s = sprites[iid];
    bool pass0 = u.f.w < 0.5;
    Dot o;
    float size = s.rect.z;
    if (pass0) {
        if (s.col.a <= 0) return hidden();
        size *= 2.4; o.col = float4(s.col.rgb, min(1.0, s.col.a * 0.6) * s.rect.w); o.soft = 1;
    } else { o.col = float4(s.col.rgb, s.rect.w); o.soft = 0; }
    o.position = corner(vid, s.rect.xy, size, u, o.local);
    return o;
}

/// 格子是圆角小方块，四周留一道缝（深色 15%，浅色 7%：浅底从缝里透出来会把整体冲淡）；底光与投影是一团柔边的光。输出预乘。
fragment float4 dotFragment(Dot in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a;
    if (in.soft > 0.5) {
        a = exp(-dot(in.local, in.local) * 3.2);
    } else {
        float gap = u.d.w > 0.5 ? 0.07 : 0.15, inner = 1 - gap, radius = inner * 0.34;
        float2 q = abs(in.local) - (inner - radius);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        float aa = fwidth(d);
        a = 1 - smoothstep(-aa, aa, d);
    }
    float alpha = clamp(in.col.a, 0.0, 1.0) * a;
    return float4(clamp(in.col.rgb, 0.0, 1.0) * alpha, alpha);
}
"""#
}
