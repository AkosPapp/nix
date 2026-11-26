#!/usr/bin/env python3
"""doc2md - any document to markdown on stdout (fleet agent-documents kit).

PDF goes through pymupdf4llm (fast, faithful text+tables); office formats
through markitdown. This is the READ path; the write path is md2office /
docx / xlsx.
"""

import sys
from pathlib import Path


def main() -> None:
    args = [a for a in sys.argv[1:]]
    tables = "--tables" in args
    paths = [a for a in args if not a.startswith("-")]
    if not paths:
        sys.exit("usage: doc2md [--tables] FILE...")
    for raw in paths:
        path = Path(raw).expanduser().resolve()
        suffix = path.suffix.lower()
        if suffix == ".pdf":
            import pymupdf4llm

            print(pymupdf4llm.to_markdown(str(path), show_tables=tables))
        else:
            from markitdown import MarkItDown

            print(MarkItDown().convert(str(path)).text_content)


if __name__ == "__main__":
    main()
