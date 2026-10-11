"""由预览图生成图标(.ico)与动作合集图(开发辅助脚本)。"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
prev = os.path.join(base, "preview")

POSES = [
    ("01_idle", "待机漂浮"), ("02_blink", "眨眼"), ("03_wave", "挥手打招呼"),
    ("04_hop", "蹦一下"), ("05_spin", "转圈圈"), ("06_burst", "放烟花"),
    ("07_pat", "被戳一下(爱心)"), ("08_surprised", "惊讶"), ("09_sleep", "睡着了"),
    ("10_stretch", "伸懒腰"), ("11_look", "东张西望"), ("12_wander", "挪个窝"),
]


def find_font(size):
    for name in ("msyh.ttc", "msyhbd.ttc", "simhei.ttf", "simsun.ttc"):
        p = os.path.join(r"C:\Windows\Fonts", name)
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def make_icon(alpha_dir):
    src = Image.open(os.path.join(alpha_dir, "01_idle.png")).convert("RGBA")
    box = (24, 18, 216, 210)          # 裁掉四周多余透明边,保留光晕
    crop = src.crop(box)
    side = max(crop.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(crop, ((side - crop.width) // 2, (side - crop.height) // 2), crop)
    icon = canvas.resize((256, 256), Image.LANCZOS)
    ico = os.path.join(base, "gemini_pet.ico")
    icon.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    icon.save(os.path.join(base, "gemini_pet.png"))
    print("icon ->", ico)


def make_sheet():
    cw, ch, pad, label_h = 240, 240, 14, 52
    cols, rows = 4, 3
    title_h = 58
    W = pad + cols * (cw + pad)
    H = title_h + pad + rows * (ch + label_h + pad)
    sheet = Image.new("RGB", (W, H), (244, 245, 250))
    d = ImageDraw.Draw(sheet)
    d.text((pad + 6, 18), "Gemini 桌面小宠物 · 动作与表情预览", font=find_font(24), fill=(40, 44, 66))
    f = find_font(17)
    for i, (stem, label) in enumerate(POSES):
        r, c = divmod(i, cols)
        x = pad + c * (cw + pad)
        y = title_h + pad + r * (ch + label_h + pad)
        d.rounded_rectangle([x - 4, y - 4, x + cw + 4, y + ch + label_h - 6], 14, fill=(255, 255, 255))
        img = Image.open(os.path.join(prev, stem + ".png")).convert("RGB")
        sheet.paste(img, (x, y))
        tw = d.textlength(label, font=f)
        d.text((x + (cw - tw) / 2, y + ch + 14), label, font=f, fill=(58, 63, 90))
    out = os.path.join(prev, "预览合集.png")
    sheet.save(out)
    print("sheet ->", out, sheet.size)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        make_icon(sys.argv[1])
    make_sheet()
