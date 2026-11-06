"""Render the Friend Chat mark to PNG (mirrors assets/logo/friend_chat_logo.svg).

Used for the launcher-icon source and a preview image. No external assets.
"""
from PIL import Image, ImageDraw, ImageFilter

S = 1024
K = S / 100.0  # SVG user units -> pixels


def P(x, y):
    return (x * K, y * K)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


STOPS = [(0.0, (0x4F, 0x46, 0xE5)), (0.55, (0x7C, 0x3A, 0xED)), (1.0, (0x1E, 0x1B, 0x4B))]


def grad_color(t):
    t = max(0.0, min(1.0, t))
    for i in range(len(STOPS) - 1):
        t0, c0 = STOPS[i]
        t1, c1 = STOPS[i + 1]
        if t <= t1:
            k = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
            return lerp(c0, c1, k)
    return STOPS[-1][1]


# --- diagonal gradient plate ------------------------------------------------
G = 512
small = Image.new("RGB", (G, G))
px = small.load()
for y in range(G):
    for x in range(G):
        px[x, y] = grad_color((x + y) / (2 * (G - 1)))
plate = small.resize((S, S), Image.BICUBIC).convert("RGBA")

radius = int(28 * K)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=radius, fill=255)

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
canvas.paste(plate, (0, 0), mask)

# --- soft mint shield glow --------------------------------------------------
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse([int(18 * K), int(14 * K), int(82 * K), int(88 * K)], fill=(52, 211, 153, 38))
canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(85)))

draw = ImageDraw.Draw(canvas, "RGBA")

# --- shield ----------------------------------------------------------------
def quad(p0, p1, p2, n=48):
    out = []
    for i in range(n + 1):
        t = i / n
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
        out.append((x, y))
    return out


def cubic(p0, p1, p2, p3, n=64):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        x = u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0]
        y = u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]
        out.append((x, y))
    return out


shield = []
shield += quad((50, 12), (76, 20), (82, 26))
shield += [(82, 48)]
shield += cubic((82, 48), (82, 68), (68, 82), (50, 90))
shield += cubic((50, 90), (32, 82), (18, 68), (18, 48))
shield += [(18, 26)]
shield += quad((18, 26), (24, 20), (50, 12))

shield_px = [P(x, y) for x, y in shield]
draw.polygon(shield_px, fill=(52, 211, 153, 8))
draw.line(shield_px + [shield_px[0]], fill=(52, 211, 153, 135), width=int(2.2 * K), joint="curve")

# --- back bubble -----------------------------------------------------------
draw.rounded_rectangle([P(24, 30), P(66, 60)], radius=int(11 * K), fill=(255, 255, 255, 240))
draw.polygon([P(31, 58), P(28, 68), P(40, 59)], fill=(255, 255, 255, 240))
for cx in (38, 46, 54):
    draw.ellipse([P(cx - 2.1, 45 - 2.1), P(cx + 2.1, 45 + 2.1)], fill=(79, 70, 229, 190))

# --- front bubble ----------------------------------------------------------
draw.rounded_rectangle([P(41.4, 43.4), P(80.6, 72.6)], radius=int(12.6 * K), fill=(42, 29, 99, 255))

front_grad = Image.new("RGBA", (S, S), (0, 0, 0, 0))
fgd = ImageDraw.Draw(front_grad)
fgd.rounded_rectangle([P(44, 46), P(78, 70)], radius=int(10 * K), fill=(255, 255, 255, 255))
# paint a mint gradient through that mask
mint_small = Image.new("RGB", (G, G))
mp = mint_small.load()
for y in range(G):
    for x in range(G):
        mp[x, y] = lerp((0x6E, 0xE7, 0xB7), (0x34, 0xD3, 0x99), (x + y) / (2 * (G - 1)))
mint = mint_small.resize((S, S), Image.BICUBIC).convert("RGBA")
canvas.paste(mint, (0, 0), front_grad.split()[3])

draw.polygon([P(66, 68), P(72, 74), P(62, 69.5)], fill=(52, 211, 153, 255))
draw.line([P(52, 58), P(70, 58)], fill=(11, 11, 20, 140), width=int(2 * K))
# round the line caps by hand
for cx in (52, 70):
    draw.ellipse([P(cx - 1, 57), P(cx + 1, 59)], fill=(11, 11, 20, 140))

# --- secure node network ---------------------------------------------------
nodes = [(72, 18), (86, 26), (76, 36)]
for a, b in ((0, 1), (1, 2), (0, 2)):
    draw.line([P(*nodes[a]), P(*nodes[b])], fill=(110, 231, 183, 140), width=int(1.1 * K))
for nx in nodes:
    draw.ellipse(
        [P(nx[0] - 2.6, nx[1] - 2.6), P(nx[0] + 2.6, nx[1] + 2.6)],
        fill=(110, 231, 183, 255),
    )
    draw.ellipse(
        [P(nx[0] - 4.6, nx[1] - 4.6), P(nx[0] + 4.6, nx[1] + 4.6)],
        outline=(52, 211, 153, 110),
        width=max(1, int(0.9 * K)),
    )

# --- plate hairline --------------------------------------------------------
draw.rounded_rectangle(
    [int(0.7 * K), int(0.7 * K), int(99.3 * K), int(99.3 * K)],
    radius=int(27.4 * K),
    outline=(255, 255, 255, 32),
    width=max(1, int(1.4 * K)),
)

out = "app/assets/logo/icon.png"
canvas.resize((512, 512), Image.LANCZOS).save("app/assets/logo/friend_chat_logo.png")
canvas.save(out)
canvas.resize((256, 256), Image.LANCZOS).save("app/assets/logo/friend_chat_logo_256.png")
print("wrote", out)
