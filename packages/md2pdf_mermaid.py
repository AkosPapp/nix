#!/usr/bin/env python3
"""md2pdf mermaid pre-pass (packages/md2pdf.nix).

Rewrites ```mermaid fenced blocks in a markdown file into raw-HTML <img>
tags pointing at SVGs rendered by mmdc (mermaid-cli), so the existing
pandoc -> Chromium print pipeline embeds diagrams as vectors.

Why pre-pass + <img> instead of pandoc filters or inline SVG:
 * pandoc renders ```mermaid as a <pre><code class=mermaid> block; a Lua
   filter could not run mmdc mid-conversion (no subprocess in the sandbox)
   and inline-<svg> embedding collides: mermaid-cli stamps EVERY chart with
   id="my-svg" and scopes its stylesheet to that id, so a second inlined
   diagram would style after the first's rules. An <img src=file://...>
   gives each SVG its own document - no id leakage - and --allow-file-access-from-files
   (which MathJax already needs) covers loading it at print time.
 * the explicit width/height attrs (from the SVG's viewBox) keep the image
   from collapsing to Chromium's 300x150 default object size - mermaid's SVG
   declares width="100%", which has no intrinsic size in an <img>.

Usage: md2pdf_mermaid.py SRC OUT.md TMPDIR MMDC PPTR_JSON STRICT
Exit: 0 ok (failures fall back to the literal code block, warnings on
stderr); 4 when STRICT=1 and a diagram failed to render.
"""

import os
import re
import subprocess
import sys

FENCE = re.compile(r"^( {0,3})(`{3,}|~{3,})[ \t]*mermaid[ \t]*$")
VIEWBOX = re.compile(r'viewBox="0 0 ([0-9.]+) ([0-9.]+)"')


def main() -> int:
    src, out_md, tmpdir, mmdc, pptr, strict = sys.argv[1:7]
    os.makedirs(tmpdir, exist_ok=True)

    with open(src, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    out = []
    i = 0
    n = 0
    failed = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue
        indent, fence = m.group(1), m.group(2)
        close = re.compile(r"^ {0,3}" + re.escape(fence[0]) + "{" + str(len(fence)) + ",}[ \t]*$")
        body = []
        i += 1
        while i < len(lines) and not close.match(lines[i]):
            body.append(lines[i])
            i += 1
        i += 1  # consume the closing fence (absent = EOF: still render what we have)

        n += 1
        mmd_path = os.path.join(tmpdir, f"diagram-{n}.mmd")
        svg_path = os.path.join(tmpdir, f"diagram-{n}.svg")
        with open(mmd_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(body) + "\n")

        proc = subprocess.run(
            [mmdc, "-i", mmd_path, "-o", svg_path, "-b", "white", "-p", pptr],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if proc.returncode != 0 or not os.path.exists(svg_path):
            failed += 1
            print(
                f"md2pdf: mermaid diagram {n} failed to render: "
                + (proc.stderr.strip().splitlines() or ["mmdc exit %d" % proc.returncode])[-1],
                file=sys.stderr,
            )
            # keep the source block verbatim so the PDF still carries the text
            out.append(f"{indent}{fence} mermaid")
            out.extend(body)
            out.append(f"{indent}{fence}")
            continue

        with open(svg_path, encoding="utf-8") as fh:
            head = fh.read(4096)
        vb = VIEWBOX.search(head)
        w = float(vb.group(1)) if vb else 600.0
        h = float(vb.group(2)) if vb else 400.0
        # Cap the print width at the A4 column (657.6px); taller boxes scale
        # down with the img's height:auto (set in the print CSS), so only the
        # explicit attrs matter for layout.
        maxw = min(w, 657.0)
        out.append("")
        out.append('<div class="md2pdf-mermaid">')
        out.append(
            f'<img src="file://{os.path.realpath(svg_path)}" width="{maxw:g}" height="{h * maxw / w:g}" alt="mermaid diagram {n}">'
        )
        out.append("</div>")
        out.append("")

    with open(out_md, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")

    if failed and strict == "1":
        print(f"md2pdf: aborting (--strict), {failed} mermaid diagram(s) failed", file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
