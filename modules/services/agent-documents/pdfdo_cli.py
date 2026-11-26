#!/usr/bin/env python3
"""pdfdo - everyday PDF surgery in one command (fleet agent-documents kit).

merge / split / rotate / watermark / text / pages: the pypdf+fitz one-liners a
document job needs most, so the agent never pastes a snippet wrong. The pdf
skill covers the rest (forms, images, OCR hand-off, reportlab authoring).
"""

import argparse
import os
import sys


def _range(spec, n):
    out = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return [p for p in out if 1 <= p <= n]


def main() -> None:
    p = argparse.ArgumentParser(prog="pdfdo", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("merge", help="concatenate PDFs")
    m.add_argument("out")
    m.add_argument("ins", nargs="+")

    s = sub.add_parser("split", help="extract a page range, or one file per page")
    s.add_argument("in_")
    s.add_argument("--pages", help="e.g. 1-3,7 (default: every page separately)")

    r = sub.add_parser("rotate", help="rotate all pages")
    r.add_argument("in_")
    r.add_argument("out")
    r.add_argument("--degrees", type=int, default=90, choices=[90, 180, 270])

    d = sub.add_parser("drop", help="delete a page range")
    d.add_argument("in_")
    d.add_argument("out")
    d.add_argument("--pages", required=True)

    t = sub.add_parser("text", help="print the text layer")
    t.add_argument("in_")
    t.add_argument("--pages")

    i = sub.add_parser("info", help="pages + metadata + form fields as JSON")
    i.add_argument("in_")

    im = sub.add_parser("images", help="rasterize pages to PNG (OCR/vision hand-off)")
    im.add_argument("in_")
    im.add_argument("--outdir", default=".")
    im.add_argument("--dpi", type=int, default=150)

    w = sub.add_parser("watermark", help="diagonal gray text stamp on every page")
    w.add_argument("in_")
    w.add_argument("out")
    w.add_argument("--text", required=True)

    a = p.parse_args()

    if a.cmd == "merge":
        import pypdf

        wtr = pypdf.PdfWriter()
        for f in a.ins:
            for pg in pypdf.PdfReader(f).pages:
                wtr.add_page(pg)
        with open(a.out, "wb") as fh:
            wtr.write(fh)
        print(a.out)
    elif a.cmd in ("split", "drop"):
        import pypdf

        rd = pypdf.PdfReader(a.in_)
        n = len(rd.pages)
        wtr = pypdf.PdfWriter()
        if a.cmd == "drop":
            idx = [i for i in range(1, n + 1) if i not in _range(a.pages, n)]
            for i in idx:
                wtr.add_page(rd.pages[i - 1])
            with open(a.out, "wb") as fh:
                wtr.write(fh)
            print(a.out)
        elif a.pages:
            for i in _range(a.pages, n):
                wtr.add_page(rd.pages[i - 1])
            out = f"{os.path.splitext(a.in_)[0]}-{a.pages}.pdf"
            with open(out, "wb") as fh:
                wtr.write(fh)
            print(out)
        else:
            for i in range(n):
                w = pypdf.PdfWriter()
                w.add_page(rd.pages[i])
                out = f"{os.path.splitext(a.in_)[0]}-{i+1}.pdf"
                with open(out, "wb") as fh:
                    w.write(fh)
                print(out)
    elif a.cmd == "rotate":
        import pypdf

        wtr = pypdf.PdfWriter(clone_from=a.in_)
        for pg in wtr.pages:
            pg.rotate(a.degrees)
        with open(a.out, "wb") as fh:
            wtr.write(fh)
        print(a.out)
    elif a.cmd == "text":
        import pymupdf as fitz

        doc = fitz.open(a.in_)
        idx = _range(a.pages, doc.page_count) if a.pages else range(1, doc.page_count + 1)
        for i in idx:
            print(f"--- page {i} ---")
            print(doc[i - 1].get_text())
    elif a.cmd == "info":
        import json

        import pymupdf as fitz

        doc = fitz.open(a.in_)
        fields = []
        for page in doc:
            for wdg in page.widgets() or []:
                fields.append({"name": wdg.field_name, "type": wdg.field_type_string, "page": page.number + 1})
        print(json.dumps({"pages": doc.page_count, "metadata": doc.metadata, "fields": fields}, indent=2, default=str))
    elif a.cmd == "images":
        import pymupdf as fitz

        os.makedirs(a.outdir, exist_ok=True)
        doc = fitz.open(a.in_)
        zoom = a.dpi / 72
        for page in doc:
            pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom))
            out = os.path.join(a.outdir, f"{os.path.splitext(os.path.basename(a.in_))[0]}-{page.number+1}.png")
            pix.save(out)
            print(out)
    elif a.cmd == "watermark":
        import pymupdf as fitz

        doc = fitz.open(a.in_)
        for page in doc:
            rect = page.rect
            page.insert_text(
                (rect.width / 3, rect.height / 2),
                a.text,
                rotate=45,
                fontsize=48,
                color=(0.75, 0.75, 0.75),
                overlay=True,
            )
        doc.save(a.out)
        print(a.out)
    else:  # pragma: no cover - argparse already rejects
        sys.exit(1)


if __name__ == "__main__":
    main()
