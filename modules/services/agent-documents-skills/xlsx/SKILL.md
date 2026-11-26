---
name: xlsx
description: "Excel .xlsx files: create/patch sheets, values, formulas, styles, charts; read/convert CSV; analyse with pandas."
---

# Excel (.xlsx)

Start from the `documents` skill. An .xlsx is a zip of XML - `unzip -o wb.xlsx
xl/worksheets/sheet1.xml` to inspect; write through the APIs.

- **Create/patch** with the CLI (JSON ops, `sheet` auto-creates):

  ```bash
  xlsx --out book.xlsx --json - <<'JSON'
  [
    {"op": "values", "sheet": "Sales", "values": [["Month","EU","APAC"],["Jan",120,80],["Feb",135,95]]},
    {"op": "formula", "sheet": "Sales", "cell": "D2", "formula": "=B2+C2"},
    {"op": "style", "sheet": "Sales", "cells": ["A1","B1","C1"], "bold": true, "fill": "DDDDDD"},
    {"op": "widths", "sheet": "Sales", "widths": {"A": 10, "B": 12, "C": 12}},
    {"op": "chart", "sheet": "Sales", "chart": "bar", "min_col": 2, "max_col": 3, "min_row": 1, "max_row": 3, "cat_col": 1, "anchor": "F2"}
  ]
  JSON
  ```

- **Read**: `xlsx --in book.xlsx --dump '*'` (sheets -> CSV on stdout, `## sheet`
  markers on stderr), or one sheet `--dump Sales`.
- **Analyse** (not edit): pandas is in the env - `office-python` with
  `pd.read_excel(...)`; write results back with the CLI, don't re-invent I/O.
- **CSV <-> xlsx**: `xlsx2csv in.xlsx > out.csv`; `office-python -c "import
  pandas as pd; pd.read_csv('in.csv').to_excel('out.xlsx', index=False)"`.
- **To PDF** (a print of the sheet): `soffice --headless --convert-to pdf
  --outdir . book.xlsx`. Formulas evaluate during that conversion;
  openpyxl itself never computes them - if you need values of formulas you
  just wrote, convert to PDF/xlsx-via-LibreOffice or compute in pandas.
- **Legacy .xls**: convert first with `soffice --headless --convert-to xlsx`.

openpyxl handles the rest (merged cells, conditional formats, protection,
multiple named styles) via `office-python`. Verify by dumping what you wrote.
