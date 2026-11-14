"""Build the publication diagram from recorded hardware topology.

Solid arrows describe the logical data path. Dashed arrows show power supply
relationships only; this is not a circuit schematic.
"""
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

HERE = Path(__file__).resolve().parent
ASSETS = HERE / "assets"
ASSETS.mkdir(parents=True, exist_ok=True)
REG = (FontProperties(fname="C:/Windows/Fonts/msyh.ttc")
       if Path("C:/Windows/Fonts/msyh.ttc").exists()
       else FontProperties(family="Noto Sans CJK SC"))
BOLD = (FontProperties(fname="C:/Windows/Fonts/msyhbd.ttc")
        if Path("C:/Windows/Fonts/msyhbd.ttc").exists()
        else FontProperties(family="Noto Sans CJK SC", weight="bold"))
plt.rcParams["svg.fonttype"] = "path"
fig, ax = plt.subplots(figsize=(15.6, 9.6), dpi=100)
fig.subplots_adjust(0, 0, 1, 1)
ax.set_xlim(0, 1560)
ax.set_ylim(960, 0)
ax.axis("off")
fig.patch.set_facecolor("white")
BLUE = "#255BA7"
INK = "#18304A"
GRAY = "#53677F"
GREEN = "#16856E"
ORANGE = "#B76520"

def text(x, y, value, size=20, color=INK, bold=False, ha="left"):
    ax.text(x, y, value, fontproperties=BOLD if bold else REG,
            fontsize=size, color=color, ha=ha, va="center", zorder=5)

def box(x, y, w, h, edge=BLUE, fill="#F2F6FC"):
    ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0,rounding_size=14",
                 linewidth=2, edgecolor=edge, facecolor=fill, zorder=3))

def path(points, color=BLUE, dash=False, arrow=True):
    xs, ys = zip(*points)
    ax.plot(xs, ys, color=color, linewidth=2.5,
            linestyle=(0, (5, 5)) if dash else "-", zorder=1)
    if arrow:
        ax.add_patch(FancyArrowPatch(points[-2], points[-1],
                     arrowstyle="-|>", mutation_scale=20, linewidth=2.5,
                     color=color, linestyle=(0, (5, 5)) if dash else "-", zorder=2))

text(60, 58, "TH3P4G3 + A770：连接与故障分支", 31, bold=True)
text(60, 108, "修改点在坞的 USB Root Hub；A770 的 DX11 / 141 问题另行追踪。", 20, GRAY)

# Logical data links.
path([(330,355),(450,355)])
path([(710,355),(815,355),(815,260),(880,260)])
path([(710,355),(815,355),(815,482),(880,482)])
path([(1160,482),(1220,482)])
path([(1360,540),(1360,610)])

# PSU relationships, deliberately styled unlike data links.
path([(580,650),(580,430)], ORANGE, dash=True)
path([(710,700),(770,700),(770,375),(1200,375),(1200,330)], ORANGE, dash=True)

box(60,280,270,150)
text(195,318,"笔记本电脑",25,bold=True,ha="center")
text(195,363,"Thunderbolt 主机",20,ha="center")
text(195,399,"ROG G634JZ",19,GRAY,ha="center")

text(390,304,"雷电线",18,GRAY,ha="center")
box(450,280,260,150)
text(580,322,"TH3P4G3",27,bold=True,ha="center")
text(580,368,"外接显卡坞",22,ha="center")
text(580,402,"单闪电口测试",18,GRAY,ha="center")

box(880,190,620,140,ORANGE,"#FFF8EF")
text(908,226,"Intel Arc A770",27,bold=True)
text(908,270,"PCI ID  8086:56A0",18,GRAY)
text(1472,303,"DX11 初始化 / 141：未解决",20,ORANGE,bold=True,ha="right")

box(880,425,280,115)
text(1020,459,"坞内 xHCI",24,bold=True,ha="center")
text(1020,503,"8086:15F0",20,GRAY,ha="center")

box(1220,425,280,115,GREEN,"#EEFAF5")
text(1360,457,"USB Root Hub",23,GREEN,bold=True,ha="center")
text(1360,500,"Enable = False",21,GREEN,bold=True,ha="center")
text(1190,582,"本次修改：关闭此 Hub 省电",16,GREEN,ha="right")

box(1220,610,280,100,GRAY,"#F6F8FA")
text(1360,644,"USB 鼠标接收器",21,bold=True,ha="center")
text(1360,684,"可选 · 对照实验变量",17,GRAY,ha="center")

box(450,650,260,100,ORANGE,"#FFF8EF")
text(580,686,"TT SFX 650 W",23,ORANGE,bold=True,ha="center")
text(580,726,"给坞与 A770 供电",18,ORANGE,ha="center")
text(608,568,"供电关系",17,ORANGE)

# Readable legend and interpretation boundary.
path([(60,690),(145,690)],arrow=False)
text(161,690,"数据路径",17,GRAY)
path([(60,735),(145,735)],ORANGE,dash=True,arrow=False)
text(161,735,"供电关系（示意）",17,GRAY)
box(60,805,1440,115,"#C6D8E8","#F7FAFD")
text(85,841,"证据支持：掉线与 USB 空闲省电路径有关；关闭目标 Hub 省电后，本机观察窗内未再掉线。",20,bold=True)
text(85,884,"这是逻辑拓扑与关联假设，非已证实的硬件电路故障；不代表禁止 A770 自身进入 D3。",19,GRAY)

fig.savefig(ASSETS / "topology.png", dpi=100, facecolor="white")
fig.savefig(ASSETS / "topology.svg", facecolor="white")
plt.close(fig)
print(ASSETS / "topology.png")
print(ASSETS / "topology.svg")
