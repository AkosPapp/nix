#!/usr/bin/env python3
"""md2pdf trailing-blank-page trim (packages/md2pdf.nix).

`---` is a page break in md2pdf (see md2pdf.css), so a document ending on a
separator - or content that exactly fills a page followed by a separator -
leaves Chromium printing one final EMPTY page. CSS :last-child guards cannot
prevent it (measured 2026-11-21: the guard also killed the break before the
last REAL content). This post-pass deletes trailing blank pages instead, and
runs BEFORE the outline-title rewrite so the bookmarks survive the rebuild.

Blank test: no extractable text AND no drawing operators (no "re" fill path,
no "Do" XObject) in the content stream - so a diagram-only last page
(vectors, no text) is never touched.

Known cosmetic tradeoff: Chromium bakes the "N / M" @page footer at print
time, so a trimmed document's surviving pages say "/ M+1" once. A blank
final page numbered "2 / 2" is the worse artifact, so the trim wins; the
trim only ever fires for documents that END on a separator.

In-place delete on a CLONE (not add-page-into-a-new-writer): chromium's
outline/bookmark tree and page labels survive page deletion untouched;
rebuilding by copying pages dropped the whole outline (measured). Best-effort:
any failure leaves the PDF as Chromium wrote it; exit 0 always (the caller
guards with || true).
"""

import sys

from pypdf import PdfReader, PdfWriter


def _blank(page) -> bool:
    try:
        if (page.extract_text() or "").strip():
            return False
        contents = page.get_contents()
        raw = contents.get_data() if contents else b""
        return b"re" not in raw and b"Do" not in raw
    except Exception:  # noqa: BLE001 - a page we cannot read we do not delete
        return False


def main() -> int:
    path = sys.argv[1]
    try:
        reader = PdfReader(path)
        if len(reader.pages) < 2 or not _blank(reader.pages[-1]):
            return 0
        writer = PdfWriter(clone_from=reader)
        trimmed = 0
        while len(writer.pages) > 1 and _blank(writer.pages[-1]):
            writer.delete_page(len(writer.pages) - 1)
            trimmed += 1
        if trimmed == 0:
            return 0
        with open(path, "wb") as fh:
            writer.write(fh)
        print(f"md2pdf: trimmed {trimmed} trailing blank page(s)")
    except Exception as e:  # noqa: BLE001
        print(f"md2pdf: blank-page trim skipped ({e})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
