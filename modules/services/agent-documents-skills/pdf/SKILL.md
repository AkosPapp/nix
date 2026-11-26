---
name: pdf
description: "PDF files: read/extract, merge/split/rotate/watermark, fill AcroForms, author with reportlab, rasterize for OCR."
---

# PDF

Start from the `documents` skill for the tool map. Quick recipes:

- **Read text**: `doc2md file.pdf` (markdown, tables optional) or per page
  `pdfdo text file.pdf --pages 1-3`. Check `pdfdo info file.pdf` first - zero
  text + many images means SCANNED: rasterize and OCR instead
  (`pdfdo images file.pdf --outdir out`, then `tesseract out/file-1.png -`).
- **Surgery** (merge/split/drop/rotate/watermark/info/images): `pdfdo <cmd>`;
  run `pdfdo` bare for the usage tree.
- **Forms**: list fields with `pdfdo info` (JSON `fields`), fill with the
  `form_fill` MCP tool (path+jail safe) or:

  ```python
  # office-python - <
  import pypdf
  r = pypdf.PdfReader("form.pdf")
  w = pypdf.PdfWriter(clone_from=r)
  for p in w.pages:
      w.update_page_form_field_values(p, {"Name": "Ada Lovelace"}, auto_regenerate=False)
  with open("filled.pdf", "wb") as fh:
      w.write(fh)
  # >
  ```

- **Author**: markdown -> `md2office x.md pdf` covers reports. For pixel
  layout (invoices, forms, exact tables) use `reportlab` via
  `office-python` (platypus flowables).
- **Convert in**: any office file -> `soffice --headless --convert-to pdf
  --outdir . file.docx`.
- **Verify output** after generating: `pdfdo info out.pdf` and eyeball page 1
  via `pdfdo images out.pdf --outdir /tmp/peek --dpi 100` + read the PNG.
  Deliver nothing you have not opened.
