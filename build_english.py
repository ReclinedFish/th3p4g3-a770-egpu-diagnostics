"""Build English figures from the same sanitized evidence as the Chinese report.

Run: python build_english.py
Requires Matplotlib. The optional HTML renderer also requires Python-Markdown.
Only reads report files and writes assets/en; never queries or modifies devices.
The topology is a logical illustration of the documented setup, not a circuit diagram.
"""
from pathlib import Path
from datetime import datetime
import json

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

BASE = Path(__file__).resolve().parent
ASSETS = BASE / "assets" / "en"
BLUE, TEAL, ORANGE = "#2864b4", "#168478", "#c66a20"
INK, GRAY = "#172b43", "#66788a"


def save(fig, name, tight=True):
    options = {"bbox_inches": "tight", "pad_inches": .3} if tight else {}
    fig.savefig(ASSETS / f"{name}.png", dpi=160, **options)
    fig.savefig(ASSETS / f"{name}.svg", **options)
    plt.close(fig)


def power_policy(data):
    fig, ax = plt.subplots(figsize=(12, 4.8))
    rows = data["ab_experiment"]
    for i, row in enumerate(rows):
        minutes = row["seconds"] / 60
        color = ORANGE if row["dock_removal_count"] else TEAL
        ax.barh(i, minutes, height=.5, color=color)
        ax.text(minutes + .3, i,
                f'{row["seconds"]:.1f} s  |  {row["dock_removal_count"]} dock removals',
                va="center", fontsize=12, color=color, fontweight="bold")
    labels = ["Hub power saving allowed\nReceiver removed",
              "Hub power saving allowed\nReceiver reconnected",
              "Hub power saving disallowed\nReceiver removed"]
    ax.set_yticks(range(3), labels)
    ax.invert_yaxis()
    ax.set_xlim(0, 22)
    ax.set_xticks([0, 3, 6, 9, 12, 15])
    ax.set_xlabel("Actual observation duration (minutes)")
    ax.grid(axis="x", alpha=.12)
    ax.set_axisbelow(True)
    ax.set_title("Changing the hub policy kept the dock connected without a receiver",
                 loc="left", fontsize=16, pad=24)
    fig.text(.02, -.02,
             "Nov 8-9, 2026 | xHCI policy unchanged | First window ended after two removals; windows were unequal.",
             fontsize=10, color=GRAY)
    fig.tight_layout()
    save(fig, "power-policy-ab")


def cables(data):
    runs = [r for r in data["cable_runs"] if r["port"] == "single_lightning"]
    original_names = ["原装雷电4线1", "贝尔金雷电5线", "原装长线2", "编织线"]
    labels = ["Original TB4 #1", "Belkin TB5", "Longer original #2", "Braided"]
    groups = [[r for r in runs if r["cable"] == name] for name in original_names]
    passed = [next(r for r in group if r["exit_code"] == 0) for group in groups]
    baseline = passed[0]["dispatches_per_second"]
    fig, (ax, bx) = plt.subplots(1, 2, figsize=(13, 4.7),
                                gridspec_kw={"width_ratios": [1.2, 1]})
    for i, row in enumerate(passed):
        value = row["dispatches_per_second"] / baseline * 100
        ax.barh(i, value, color=BLUE, height=.5)
        ax.text(value + 1, i, f"{value:.2f}", va="center", fontsize=11)
    ax.set_xlim(0, 119)
    ax.set_yticks(range(4), labels)
    ax.invert_yaxis()
    ax.set_xlabel("Successful-run dispatch rate\nOriginal TB4 #1 = 100")
    ax.set_title("Completed runs differed by less than 0.3%", fontsize=13, loc="left", pad=18)
    ax.grid(axis="x", alpha=.1)
    ax.set_axisbelow(True)
    for i, group in enumerate(groups):
        successes = sum(r["exit_code"] == 0 for r in group)
        failures = len(group) - successes
        bx.barh(i, successes, color=TEAL, height=.5, label="Passed" if i == 0 else None)
        bx.barh(i, failures, left=successes, color=ORANGE, height=.5,
                label="Initialization failed" if i == 0 else None)
        bx.text(successes / 2, i, str(successes), color="white", ha="center", va="center", fontweight="bold")
        if failures:
            bx.text(successes + failures / 2, i, str(failures), color="white", ha="center", va="center", fontweight="bold")
    bx.set_xlim(0, 3.6)
    bx.set_xticks([0, 1, 2, 3])
    bx.set_yticks(range(4), labels)
    bx.invert_yaxis()
    bx.set_xlabel("Recorded starts\nUnequal sample sizes")
    bx.set_title("Similar throughput; intermittent init failures", fontsize=13, loc="left", pad=18)
    handles, legend_labels = bx.get_legend_handles_labels()
    fig.legend(handles, legend_labels, loc="upper right", bbox_to_anchor=(.98, -.01),
               frameon=False, ncol=2, fontsize=10)
    fig.suptitle("Same single-lightning port | Receiver absent | Hub power saving off | A770 driver 9175",
                 fontsize=15, y=1.04)
    fig.text(.02, -.12,
             "Native D3D11 compute in this test only: not game FPS, a desktop PCIe comparison, or estimated cable failure rates.",
             fontsize=10, color=GRAY)
    fig.tight_layout(w_pad=3)
    save(fig, "cable-comparison")


def compute(data):
    record = data["compute_30m"]
    start = datetime.fromisoformat(record["start"])
    rows = record["temperature_power_samples"]
    x = [(datetime.fromisoformat(r["time"]) - start).total_seconds() / 60 for r in rows]
    stats = record["sensor"]["entire"]
    fig, (ax, bx) = plt.subplots(2, 1, figsize=(12, 5.2), sharex=True)
    ax.plot(x, [r["core_c"] for r in rows], color=TEAL, linewidth=1.7)
    ax.set_ylim(65, 75)
    ax.set_ylabel("Core temperature (°C)")
    ax.text(.99, .85, f'Recorded range: {stats["temp_min"]:g}-{stats["temp_max"]:g}°C',
            transform=ax.transAxes, ha="right", color=TEAL)
    bx.plot(x, [r["board_power_w"] for r in rows], color=BLUE, linewidth=1.4)
    bx.set_ylim(170, 205)
    bx.set_ylabel("Board power (W)")
    bx.text(.99, .85,
            f'Mean: {stats["power_avg"]:.2f} W | Range: {stats["power_min"]:g}-{stats["power_max"]:g} W',
            transform=bx.transAxes, ha="right", color=BLUE)
    bx.set_xlim(0, 30)
    bx.set_xlabel("Compute observation time (minutes)")
    for axis in (ax, bx):
        axis.grid(alpha=.15)
    fig.suptitle("Temperature and power during a 30-minute compute workload",
                 fontsize=17, x=.06, ha="left")
    fig.text(.06, -.01,
             f'Nov 13, 2026, 20:11-20:41 HST | {stats["samples"]} sensor samples | '
             f'Longest sampling gap: {stats["max_gap_seconds"]:g} s | Not continuous per-frame monitoring.',
             fontsize=10, color=GRAY)
    fig.tight_layout(rect=(0, .03, 1, .95))
    save(fig, "compute-30min")


def topology():
    fig, ax = plt.subplots(figsize=(15.6, 9.6))
    fig.subplots_adjust(0, 0, 1, 1)
    ax.set_xlim(0, 1560)
    ax.set_ylim(960, 0)
    ax.axis("off")

    def text(x, y, value, size=20, color=INK, bold=False, ha="left"):
        ax.text(x, y, value, fontsize=size, fontweight="bold" if bold else "normal",
                color=color, ha=ha, va="center", zorder=5)

    def box(x, y, w, h, edge=BLUE, fill="#F2F6FC"):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=14",
                                    linewidth=2, edgecolor=edge, facecolor=fill, zorder=3))

    def path(points, color=BLUE, dash=False, arrow=True):
        xs, ys = zip(*points)
        style = (0, (5, 5)) if dash else "-"
        ax.plot(xs, ys, color=color, linewidth=2.5, linestyle=style, zorder=1)
        if arrow:
            ax.add_patch(FancyArrowPatch(points[-2], points[-1], arrowstyle="-|>",
                                        mutation_scale=20, linewidth=2.5, color=color,
                                        linestyle=style, zorder=2))

    text(60, 58, "TH3P4G3 + A770: connections and fault paths", 30, bold=True)
    text(60, 108, "The change targets the dock's USB Root Hub. DX11 / 141 remains a separate issue.", 19, GRAY)
    path([(330, 355), (450, 355)])
    path([(710, 355), (815, 355), (815, 260), (880, 260)])
    path([(710, 355), (815, 355), (815, 482), (880, 482)])
    path([(1160, 482), (1220, 482)])
    path([(1360, 540), (1360, 610)])
    path([(580, 650), (580, 430)], ORANGE, dash=True)
    path([(710, 700), (770, 700), (770, 375), (1200, 375), (1200, 330)], ORANGE, dash=True)

    box(60, 280, 270, 150)
    text(195, 318, "Laptop", 25, bold=True, ha="center")
    text(195, 363, "Thunderbolt host", 19, ha="center")
    text(195, 399, "ROG G634JZ", 19, GRAY, ha="center")
    text(390, 304, "TB cable", 17, GRAY, ha="center")
    box(450, 280, 260, 150)
    text(580, 322, "TH3P4G3", 27, bold=True, ha="center")
    text(580, 368, "eGPU dock", 22, ha="center")
    text(580, 402, "Single-lightning port", 15, GRAY, ha="center")

    box(880, 190, 620, 140, ORANGE, "#FFF8EF")
    text(908, 226, "Intel Arc A770", 27, bold=True)
    text(908, 270, "PCI ID  8086:56A0", 18, GRAY)
    text(1472, 303, "DX11 init / 141: unresolved", 19, ORANGE, bold=True, ha="right")
    box(880, 425, 280, 115)
    text(1020, 459, "Dock USB xHCI", 20, bold=True, ha="center")
    text(1020, 503, "8086:15F0", 20, GRAY, ha="center")
    box(1220, 425, 280, 115, TEAL, "#EEFAF5")
    text(1360, 454, "USB Root Hub", 21, TEAL, bold=True, ha="center")
    text(1360, 485, "Power policy", 15, TEAL, ha="center")
    text(1360, 517, "Enable = False", 19, TEAL, bold=True, ha="center")
    text(1190, 582, "Changed: hub idle power saving", 16, TEAL, ha="right")
    box(1220, 610, 280, 100, GRAY, "#F6F8FA")
    text(1360, 644, "USB mouse receiver", 17, bold=True, ha="center")
    text(1360, 684, "Optional test variable", 15, GRAY, ha="center")

    box(450, 650, 260, 100, ORANGE, "#FFF8EF")
    text(580, 686, "TT SFX 650 W", 22, ORANGE, bold=True, ha="center")
    text(580, 726, "Powers dock + A770", 15, ORANGE, ha="center")
    text(608, 568, "Power", 16, ORANGE)
    path([(60, 690), (145, 690)], arrow=False)
    text(161, 690, "Data path", 17, GRAY)
    path([(60, 735), (145, 735)], ORANGE, dash=True, arrow=False)
    text(161, 735, "Power (schematic)", 16, GRAY)
    box(60, 795, 1440, 135, "#C6D8E8", "#F7FAFD")
    text(85, 829, "Evidence links dock removals to the USB idle power path; no removals in the tested policy window.",
         16, bold=True)
    text(85, 870, "Enable=False changes the hub's power-saving permission; it does not disable the hub or force the GPU to stay in D0.",
         15, GRAY)
    text(85, 908, "Logical connections and a working hypothesis, not proof of a specific circuit fault.", 15, GRAY)
    save(fig, "topology", tight=False)


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    data = json.loads((BASE / "evidence.json").read_text(encoding="utf-8"))
    plt.rcParams.update({
        "font.family": "DejaVu Sans", "font.size": 12, "axes.unicode_minus": False,
        "figure.facecolor": "#ffffff", "axes.facecolor": "#ffffff",
        "text.color": INK, "axes.labelcolor": "#41546b",
        "xtick.color": "#41546b", "ytick.color": INK,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.spines.left": False, "axes.spines.bottom": False,
        "svg.fonttype": "path", "savefig.facecolor": "#ffffff",
    })
    power_policy(data)
    cables(data)
    compute(data)
    topology()
    if (BASE / "render_reports.py").exists():
        from render_reports import render_reports
        render_reports()
    print("Rendered English figures in", ASSETS)


if __name__ == "__main__":
    main()
