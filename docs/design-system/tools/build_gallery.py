"""Builds one HTML page that shows every component preview with the tokens applied.

Usage: python3 docs/design-system/tools/build_gallery.py docs/design-system /tmp/quill-design-system.html
The output is a local file to open in a browser; it is not committed.
"""
import html
import json
import os
import re
import sys

ROOT, OUT = sys.argv[1], sys.argv[2]


def tokens_css(tokens):
    themes = [t["id"] for t in tokens["color"]["themes"]]
    blocks = {theme: [] for theme in themes}
    for token in tokens["color"]["tokens"]:
        value = token["value"]
        for theme in themes:
            v = value if isinstance(value, str) else value.get(theme, value.get(themes[0]))
            blocks[theme].append(f"--{token['name']}: {v};")
    shared = []
    for family in ("spacing", "radius", "shadow", "opacity", "size"):
        for token in tokens.get(family, {}).get("tokens", []):
            value = token["value"]
            if isinstance(value, dict):
                # Per-theme values (a shadow, for example) go with the colors.
                for theme in themes:
                    blocks[theme].append(f"--{token['name']}: {value.get(theme, value.get(themes[0]))};")
            else:
                shared.append(f"--{token['name']}: {value};")
    for key, stack in tokens["type"]["families"].items():
        shared.append(f"--font-{key}: {stack};")
    css = f":root, [data-theme=\"{themes[0]}\"] {{ {' '.join(blocks[themes[0]])} }}\n"
    for theme in themes[1:]:
        css += f"[data-theme=\"{theme}\"] {{ {' '.join(blocks[theme])} }}\n"
    return css + f":root {{ {' '.join(shared)} }}\n"


def main():
    with open(os.path.join(ROOT, "tokens.json")) as f:
        tokens = json.load(f)
    with open(os.path.join(ROOT, "components", "bundle.css")) as f:
        bundle_css = f.read()
    with open(os.path.join(ROOT, "components", "bundle.js")) as f:
        header = json.loads(re.match(r"/\* @ds-bundle: (.*) \*/", f.readline()).group(1))
    style = tokens_css(tokens) + bundle_css

    sections, current = [], None
    for entry in header["components"]:
        name = entry["name"]
        with open(os.path.join(ROOT, "components", name, "preview.html")) as f:
            preview = f.read()
        marker = re.match(r'<!-- @dsCard group="([^"]*)" height=(\d+)', preview)
        group, height = marker.group(1), int(marker.group(2))
        body = preview.split("<body>", 1)[1].rsplit("</body>", 1)[0]
        doc = f'<!doctype html><html data-theme="light"><head><meta charset="utf-8"><style>{style}</style></head><body>{body}</body></html>'
        if group != current:
            sections.append(f"<h2>{html.escape(group)}</h2>")
            current = group
        sections.append(
            f'<section><h3>{html.escape(name)}</h3>'
            f'<iframe srcdoc="{html.escape(doc, quote=True)}" style="height:{height + 40}px"></iframe></section>'
        )

    page = f"""<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>Quill Design System</title>
<style>
body {{ margin: 0; padding: 24px; font: 13px -apple-system, system-ui, sans-serif; background: #f2f2f4; color: #1d1d1f; }}
h1 {{ font-size: 22px; margin: 0 0 8px; }} h2 {{ font-size: 15px; margin: 32px 0 8px; }} h3 {{ font-size: 12px; margin: 0 0 6px; color: #555; }}
section {{ margin-bottom: 16px; }} iframe {{ width: 100%; max-width: 1100px; border: 0; border-radius: 8px; background: #fff; display: block; }}
label {{ font-size: 12px; }}
</style></head><body>
<h1>Quill Design System</h1>
<label><input type="checkbox" id="dark"> 다크 테마</label>
{''.join(sections)}
<script>
document.getElementById('dark').addEventListener('change', e => {{
  for (const frame of document.querySelectorAll('iframe')) {{
    frame.contentDocument.documentElement.dataset.theme = e.target.checked ? 'dark' : 'light';
  }}
}});
</script>
</body></html>
"""
    with open(OUT, "w") as f:
        f.write(page)
    print(f"{len(header['components'])} components -> {OUT}")


main()
