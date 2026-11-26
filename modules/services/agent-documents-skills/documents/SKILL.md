---
name: documents
description: "Fleet document/office tool map: which CLI/MCP to use for any PDF, Word, Excel or conversion job. Read this first, then the format-specific skill."
---

# Fleet document toolkit

Everything below is installed by `MODULES.services.agentDocuments` and is on
PATH in this session. Prefer one CLI call over hand-rolled code; drop to
`office-python` (the pinned env: pymupdf/fitz, pypdf, pdfplumber, reportlab,
python-docx, python-pptx, openpyxl, pandas, markitdown, Pillow) only when the
CLIs' flags cannot express the job.

| Job | Do this |
| --- | --- |
| read any doc (pdf/docx/xlsx/pptx/html) as markdown | `doc2md [--tables] file` |
| write a report/letter as PDF | author `report.md`, then `md2office report.md pdf` |
| PDF with LaTeX math, mermaid diagrams, or `---` page breaks | `md2pdf report.md` (on fleet boxes where `MODULES.dev.md2pdf` is on; `command -v md2pdf` first, else use the line above) |
| write/edit Word | `docx --out new.docx --json ops.json` (see docx skill) |
| write/edit Excel | `xlsx --out wb.xlsx --json ops.json` (see xlsx skill) |
| merge/split/rotate/watermark/OCR-prep PDFs | `pdfdo` (see pdf skill) |
| legacy .doc/.rtf/.odt | `office2docx old.doc` first, then edit the .docx |
| any office <-> office/pdf format | `soffice --headless --convert-to TARGET --outdir DIR file` (first run bootstraps a profile, ~10 s) |
| scanned PDF -> text | `pdfdo images scan.pdf --outdir out` then `tesseract out/scan-1.png -` (tesseract is on PATH on fleet agent hosts) |

A `documents` MCP server (tools `doc_extract`, `pdf_info`, `pdf_pages`,
`pdf_merge`, `form_fill`, `office_convert`) mirrors the same operations as
sandboxed calls: paths are jail-resolved under the session HOME, so it is the
right tool when writing outside the working area would be a mistake. Prefer
the CLIs for speed; prefer the MCP tools when an app sandbox applies.

Rules that keep output honest:

- Write deliverables under the current working directory (omp: `./out/`),
  never onto paths you did not create; agents in sandboxes resolve
  everything under their HOME.
- `office-python` is the fleet docs env. `python` answers the same ONLY in
  Hermes' units (where the shim shadows the system one); on omp hosts bare
  `python`/`python3` are the system interpreters and do NOT import
  docx/openpyxl - always type `office-python` in commands you author.
- After producing a PDF, verify it: `pdfdo info out.pdf` (pages/metadata) and,
  for layout-critical work, `pdfdo images out.pdf --outdir /tmp/peek` + look
  at the PNG.
