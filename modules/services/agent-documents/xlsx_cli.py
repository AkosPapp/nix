#!/usr/bin/env python3
"""xlsx - create/patch Excel .xlsx files from JSON ops (fleet agent-documents kit).

The xlsx skill teaches this CLI first and the raw openpyxl API (via
`office-python`) for anything deeper (conditional formatting, pivots, merged
cells, protection). Values land as data; keep formulas in `formula` ops so the
CLI never stringifies them by accident.
"""

import argparse
import json
import sys

import openpyxl


def _sheet(wb, op):
    if "sheet" not in op:
        return wb.active
    name = op["sheet"]
    if name in wb.sheetnames:
        return wb[name]
    return wb.create_sheet(name)


def main() -> None:
    p = argparse.ArgumentParser(prog="xlsx", description="create/patch .xlsx from JSON ops")
    p.add_argument("--in", dest="inp", help="open an existing .xlsx instead of a new one")
    p.add_argument("--out", required=True, help="output .xlsx path")
    p.add_argument("--json", help="JSON file: list of ops (see the xlsx skill)")
    p.add_argument("--dump", help="sheet name -> CSV on stdout (default: all sheets)")
    a = p.parse_args()

    # data_only=False keeps formulas; data_only=True (via --values) reads the
    # cached results a spreadsheet app saved - pick per job.
    wb = openpyxl.load_workbook(a.inp) if a.inp else openpyxl.Workbook()

    if a.dump:
        import csv as _csv

        names = [a.dump] if a.dump != "*" else wb.sheetnames
        for name in names:
            ws = wb[name]
            print(f"## {name}", file=sys.stderr)
            w = _csv.writer(sys.stdout)
            for row in ws.iter_rows(values_only=True):
                w.writerow(["" if v is None else v for v in row])
        return

    if a.json:
        ops = json.load(sys.stdin if a.json == "-" else open(a.json))
        for op in ops:
            kind = op.get("op")
            ws = _sheet(wb, op)
            if kind == "values":  # 2D array laid out from position (default A1)
                pos = op.get("position", "A1")
                col0, row0 = openpyxl.utils.cell.coordinate_from_string(pos)
                c0 = openpyxl.utils.column_index_from_string(col0)
                for ri, row in enumerate(op["values"]):
                    for ci, v in enumerate(row):
                        ws.cell(row=row0 + ri, column=c0 + ci, value=v)
            elif kind == "formula":  # {"cell": "B2", "formula": "=SUM(A2:A9)"}
                ws[op["cell"]] = op["formula"]
            elif kind == "style":  # {"cells": [...], "bold": true, "fill": "FFFF00", ...}
                from openpyxl.styles import Font, PatternFill

                for ref in op["cells"]:
                    cell = ws[ref]
                    if op.get("bold"):
                        cell.font = Font(bold=True)
                    if op.get("fill"):
                        cell.fill = PatternFill("solid", fgColor=op["fill"])
                    if "number_format" in op:
                        cell.number_format = op["number_format"]
            elif kind == "widths":  # {"A": 24, "B": 10}
                for col, w in op["widths"].items():
                    ws.column_dimensions[col].width = w
            elif kind == "rename":
                ws.title = op["name"]
            elif kind == "chart":
                from openpyxl.chart import BarChart, LineChart, PieChart, Reference

                data = Reference(ws, min_col=op["min_col"], min_row=op["min_row"], max_row=op["max_row"], max_col=op.get("max_col", op["min_col"]))
                chart = {"bar": BarChart, "line": LineChart, "pie": PieChart}[op.get("chart", "bar")]()
                chart.add_data(data, titles_from_data=op.get("titles_from_data", True))
                if "cat_col" in op:
                    cats = Reference(ws, min_col=op["cat_col"], min_row=op["cat_row"] if "cat_row" in op else op["min_row"], max_row=op["max_row"])
                    chart.set_categories(cats)
                chart.title = op.get("title", "")
                ws.add_chart(chart, op.get("anchor", "F2"))
            elif kind == "freeze":  # {"cell": "A2"}
                ws.freeze_panes = op.get("cell", "A2")
            else:
                sys.exit(f"xlsx: unknown op {kind!r}")

    wb.save(a.out)
    print(a.out)


if __name__ == "__main__":
    main()
