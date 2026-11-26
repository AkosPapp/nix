#!/usr/bin/env python3
"""docx - create/patch Word .docx files from JSON ops (fleet agent-documents kit).

The docx skill teaches this CLI first and the raw python-docx API (via
`office-python`) for everything else. Ops are applied in order; --in keeps an
existing document's content and styles intact (python-docx round-trips).
"""

import argparse
import json
import sys

from docx import Document


def main() -> None:
    p = argparse.ArgumentParser(prog="docx", description="create/patch .docx from JSON ops")
    p.add_argument("--in", dest="inp", help="open an existing .docx instead of a new one")
    p.add_argument("--out", required=True, help="output .docx path")
    p.add_argument("--title", help="core-properties title")
    p.add_argument("--author", help="core-properties author")
    p.add_argument("--json", help="JSON file: list of ops (see the docx skill)")
    p.add_argument("--dump", action="store_true", help="print paragraphs (text + style) and exit")
    a = p.parse_args()

    doc = Document(a.inp) if a.inp else Document()

    if a.dump:
        for para in doc.paragraphs:
            print(f"[{para.style.name}] {para.text}")
        for i, t in enumerate(doc.tables):
            print(f"[table {i}] {len(t.rows)}x{len(t.columns)}")
        return

    if a.title:
        doc.core_properties.title = a.title
    if a.author:
        doc.core_properties.author = a.author

    if a.json:
        ops = json.load(sys.stdin if a.json == "-" else open(a.json))
        for op in ops:
            kind = op.get("op")
            text = op.get("text", "")
            style = op.get("style")
            if kind == "heading":
                doc.add_heading(text, level=int(op.get("level", 1)))
            elif kind == "para":
                doc.add_paragraph(text, style=style)
            elif kind == "bullet":
                doc.add_paragraph(text, style=style or "List Bullet")
            elif kind == "number":
                doc.add_paragraph(text, style=style or "List Number")
            elif kind == "table":
                rows = op.get("rows") or [[""]]
                t = doc.add_table(rows=len(rows), cols=len(rows[0]))
                t.style = style or "Table Grid"
                for ri, row in enumerate(rows):
                    for ci, val in enumerate(row):
                        t.rows[ri].cells[ci].text = str(val)
            elif kind == "image":
                from docx.shared import Inches

                doc.add_picture(
                    op["path"],
                    width=None if "width_in" not in op else Inches(float(op["width_in"])),
                )
            elif kind == "pagebreak":
                doc.add_page_break()
            elif kind == "replace":  # whole-run text replace across the body
                old, new = op["old"], op.get("new", "")
                n = 0
                for para in doc.paragraphs:
                    for run in para.runs:
                        if old in run.text:
                            run.text = run.text.replace(old, new)
                            n += 1
                print(f"docx: replaced {n} runs of {old!r}", file=sys.stderr)
            else:
                sys.exit(f"docx: unknown op {kind!r}")

    doc.save(a.out)
    print(a.out)


if __name__ == "__main__":
    main()
