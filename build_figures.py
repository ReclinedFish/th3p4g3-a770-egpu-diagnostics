"""Render the public, sanitized evidence. Requires matplotlib and Python-Markdown.

Run from any directory: python build_figures.py
Uses only local evidence and report files; no device access.
"""
from pathlib import Path
from datetime import datetime
import json

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from render_reports import render_reports

BASE = Path(__file__).resolve().parent
DATA = json.loads((BASE / "evidence.json").read_text(encoding="utf-8"))
ASSETS = BASE / "assets"
ASSETS.mkdir(exist_ok=True)
for path in [Path("C:/Windows/Fonts/msyh.ttc"), Path("C:/Windows/Fonts/msyhbd.ttc")]:
    if path.exists():
        font_manager.fontManager.addfont(str(path))
available_fonts = {f.name for f in font_manager.fontManager.ttflist}
font_families = [n for n in ["Microsoft YaHei", "Noto Sans CJK SC", "DejaVu Sans"] if n in available_fonts]
plt.rcParams.update({
    "font.family": font_families,
    "font.size": 12, "axes.unicode_minus": False,
    "figure.facecolor": "#ffffff", "axes.facecolor": "#ffffff",
    "text.color": "#172b43", "axes.labelcolor": "#41546b",
    "xtick.color": "#41546b", "ytick.color": "#172b43",
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.spines.left": False, "axes.spines.bottom": False,
    "svg.fonttype": "path", "savefig.facecolor": "#ffffff",
})
BLUE, TEAL, ORANGE, LIGHT = "#2864b4", "#168478", "#c66a20", "#e5edf5"


def save(fig, name):
    fig.savefig(ASSETS / f"{name}.png", dpi=160, bbox_inches="tight", pad_inches=.3)
    fig.savefig(ASSETS / f"{name}.svg", bbox_inches="tight", pad_inches=.3)
    plt.close(fig)


fig, ax = plt.subplots(figsize=(11, 4.5))
rows = DATA["ab_experiment"]
labels = ["允许 Hub 省电\n接收器拔出", "允许 Hub 省电\n接收器插回", "禁止 Hub 省电\n接收器拔出"]
for i, r in enumerate(rows):
    minutes = r["seconds"] / 60
    color = ORANGE if r["dock_removal_count"] else TEAL
    ax.barh(i, minutes, height=.5, color=color)
    ax.text(minutes + .3, i, f'{r["seconds"]:.1f} 秒  ·  {r["dock_removal_count"]} 次整坞移除',
            va="center", fontsize=12, color=color, fontweight="bold")
ax.set_yticks(range(3), labels)
ax.invert_yaxis()
ax.set_xlim(0, 21)
ax.set_xticks([0, 3, 6, 9, 12, 15])
ax.set_xlabel("实际观察时长 / 分钟")
ax.grid(axis="x", alpha=.12)
ax.set_axisbelow(True)
ax.set_title("拔掉接收器后，改变 Hub 省电权限仍可抑制掉线", loc="left", fontsize=17, pad=22)
fig.text(.02, -.02, "2026-11-08 至 11-09 · xHCI 策略未改 · 第一阶段出现两次移除后结束；观察窗口不等长。", fontsize=10, color="#66788a")
fig.tight_layout()
save(fig, "power-policy-ab")


runs = [r for r in DATA["cable_runs"] if r["port"] == "single_lightning"]
names = ["原装雷电4线1", "贝尔金雷电5线", "原装长线2", "编织线"]
groups = [[r for r in runs if r["cable"] == name] for name in names]
passed = [next(r for r in g if r["exit_code"] == 0) for g in groups]
baseline = passed[0]["dispatches_per_second"]
fig, axes = plt.subplots(1, 2, figsize=(12, 4.7), gridspec_kw={"width_ratios": [1.2, 1]})
ax, bx = axes
for i, r in enumerate(passed):
    value = r["dispatches_per_second"] / baseline * 100
    ax.barh(i, value, color=BLUE, height=.5)
    ax.text(value + 1, i, f"{value:.2f}", va="center", fontsize=11)
ax.set_xlim(0, 119)
ax.set_yticks(range(4), names)
ax.invert_yaxis()
ax.set_xlabel("成功长测的调度速率指数，原装线1 = 100")
ax.set_title("完成长测后，吞吐差距不足 0.3%", fontsize=14, loc="left", pad=17)
ax.grid(axis="x", alpha=.1)
ax.set_axisbelow(True)
for i, g in enumerate(groups):
    successes = sum(r["exit_code"] == 0 for r in g)
    failures = len(g) - successes
    bx.barh(i, successes, color=TEAL, height=.5, label="成功" if i == 0 else None)
    bx.barh(i, failures, left=successes, color=ORANGE, height=.5, label="初始化失败" if i == 0 else None)
    bx.text(successes / 2, i, str(successes), color="white", ha="center", va="center", fontweight="bold")
    if failures:
        bx.text(successes + failures / 2, i, str(failures), color="white", ha="center", va="center", fontweight="bold")
bx.set_xlim(0, 3.6)
bx.set_xticks([0, 1, 2, 3])
bx.set_yticks(range(4), names)
bx.invert_yaxis()
bx.set_xlabel("记录的启动次数，样本数不同")
bx.set_title("性能接近，初始化仍会失败", fontsize=14, loc="left", pad=17)
bx.legend(loc="lower right", bbox_to_anchor=(1.05, -.36), frameon=False, ncol=2, fontsize=10)
fig.suptitle("同一单闪电口 · 接收器未插 · Hub 省电禁用 · A770 驱动 9175", fontsize=16, y=1.04)
fig.text(.02, -.11, "仅比较本程序原生 D3D11 计算负载；不是游戏 FPS、桌面直插损失或线材故障率。", fontsize=10, color="#66788a")
fig.tight_layout(w_pad=2.5)
save(fig, "cable-comparison")


c = DATA["compute_30m"]
t0 = datetime.fromisoformat(c["start"])
rows = c["temperature_power_samples"]
x = [(datetime.fromisoformat(r["time"]) - t0).total_seconds() / 60 for r in rows]
fig, (ax, bx) = plt.subplots(2, 1, figsize=(11.5, 5.2), sharex=True)
ax.plot(x, [r["core_c"] for r in rows], color=TEAL, linewidth=1.7)
ax.set_ylim(65, 75)
ax.set_ylabel("核心温度 / °C")
ax.text(.99, .85, "记录范围 71–72°C", transform=ax.transAxes, ha="right", color=TEAL)
bx.plot(x, [r["board_power_w"] for r in rows], color=BLUE, linewidth=1.4)
bx.set_ylim(170, 205)
bx.set_ylabel("板卡功耗 / W")
bx.text(.99, .85, "均值 189.29 W · 范围 187–193 W", transform=bx.transAxes, ha="right", color=BLUE)
bx.set_xlim(0, 30)
bx.set_xlabel("计算负载观察时间 / 分钟")
for ax in (ax, bx):
    ax.grid(alpha=.15)
fig.suptitle("30 分钟计算负载的温度与功耗记录", fontsize=17, x=.06, ha="left")
fig.text(.06, -.01, "2026-11-13 20:11–20:41 HST · 348 个传感器样本，最长采样间隔 12.7 秒 · 非逐帧连续监测。", fontsize=10, color="#66788a")
fig.tight_layout(rect=(0, .03, 1, .95))
save(fig, "compute-30min")


render_reports()
print("Rendered Chinese figures and both HTML reports in", BASE)
