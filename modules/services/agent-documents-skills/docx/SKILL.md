---
name: docx
description: "Word .docx files: create, patch (text/tables/styles), read, template-fill, convert to/from PDF."
---

# Word (.docx)

Start from the `documents` skill. A .docx is a zip of XML - `unzip -o file.docx
word/document.xml` when you must see the truth; edit through the APIs, never by
hand-zipping.

- **Create/patch** with the CLI (JSON ops applied in order):

  ```bash
  docx --out report.docx --json - <<'JSON'
  [
    {"op": "heading", "text": "Q4 Report", "level": 1},
    {"op": "para", "text": "Revenue grew 12%."},
    {"op": "bullet", "text": "APAC led growth"},
    {"op": "table", "rows": [["Region","Growth"],["APAC","18%"],["EU","9%"]], "style": "Table Grid"},
    {"op": "replace", "old": "12%", "new": "11.8%"}
  ]
  JSON
  ```

  `--in existing.docx` patches in place (copy first if the original must
  survive); `--dump` reads the structure back for verification.

- **Anything deeper** (run-level formatting, headers/footers, sections,
  comments, tracked changes): python-docx through `office-python` - full API
  under `<office-python> -c "import docx"`.
- **Templates**: a corporate .docx used as a style donor ->
  `pandoc content.md --reference-doc=corp.docx -o out.docx`; or open the
  template with `docx --in` and append ops.
- **To PDF**: `soffice --headless --convert-to pdf --outdir . report.docx`.
  To markdown: `doc2md report.docx`.
- **Legacy .doc**: `office2docx old.doc` first.

Verify like a reader: convert your own .docx to PDF and look at the first page
(`pdfdo images report.pdf --outdir /tmp/peek`). Fonts on fleet boxes: DejaVu,
Liberation (metric-compatible with Arial/Times), Noto.
