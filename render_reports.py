"""Render the Chinese and English reports using only local Markdown files.

Requires Python-Markdown. No hardware, network, or system settings are accessed.
"""
from html import escape
from pathlib import Path

import markdown

BASE = Path(__file__).resolve().parent
CSS = """
body{margin:0;background:#edf2f7;color:#203147;font:16px/1.85 system-ui,"Microsoft YaHei",sans-serif}
main{max-width:1000px;margin:35px auto;background:white;padding:48px 60px;border-radius:14px}
h1{font-size:30px;line-height:1.4;color:#143c65}h2{margin-top:40px;font-size:23px;color:#174c70}
p{margin:18px 0}img{max-width:100%;height:auto;display:block;margin:24px auto}
a{color:#1765ae}table{width:100%;border-collapse:collapse;font-size:14px;line-height:1.6;margin:24px 0}
th,td{text-align:left;padding:11px 13px;border-bottom:1px solid #dce5ed;overflow-wrap:anywhere}th{background:#edf4f8}
code{font-size:.9em;background:#eff3f7;padding:2px 5px;border-radius:4px;overflow-wrap:anywhere}
pre{padding:18px;background:#eff3f7;overflow:auto}pre code{padding:0;overflow-wrap:normal}
blockquote{margin:20px 0;border-left:4px solid #168478;background:#eef8f5;padding:12px 20px}
@media(max-width:700px){main{padding:24px 18px;margin:0;border-radius:0}h1{font-size:25px}table{display:block;overflow:auto}}
@media print{body{background:white}main{margin:0;padding:0;max-width:none}img,table,pre{break-inside:avoid}h2{break-after:avoid}a{color:inherit}}
"""


def render_reports():
    editions = [
        ("README.md", "report.html", "zh-CN", "TH3P4G3 外接 A770 掉线排查报告"),
        ("README.en.md", "report.en.html", "en", "TH3P4G3 and Arc A770 disconnect investigation"),
    ]
    for source, target, lang, title in editions:
        path = BASE / source
        if not path.exists():
            continue
        body = markdown.markdown(path.read_text(encoding="utf-8"), extensions=["tables", "fenced_code"])
        for src, dest, *_ in editions:
            body = body.replace(f'href="{src}"', f'href="{dest}"')
        html = (
            f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{escape(title)}</title><style>{CSS}</style></head>'
            f'<body><main>{body}</main></body></html>\n'
        )
        (BASE / target).write_text(html, encoding="utf-8")
        print("Rendered", target)


if __name__ == "__main__":
    render_reports()
