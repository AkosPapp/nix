#!/usr/bin/env python3
"""Fleet `documents` MCP server (stdio) - structured office/PDF operations.

Serves the tools the pdf/docx/xlsx skills cannot express as one CLI line:
page surgery, AcroForm fill, LibreOffice conversion, whole-document markdown
extraction. Every path argument is resolved under the calling agent's HOME
(DOCS_WORK_ROOT overrides) and must stay inside it: Hermes runs in a sandbox
whose HOME *is* its whole visible filesystem (defense in depth), while omp's
HOME is the real user home - there, the skill doctrine (write only under the
session workspace) is the rule this tool layer keeps honest about refusing to
violate silently.

Runs on the MODULES.services.agentDocuments python env (whose `mcp` is the
2.x SDK on the pinned nixpkgs-unstable - the high-level MCPServer whose
schemas derive from type hints; tools return plain strings/dicts and NEVER
raise: an exception surfaces as "Error executing tool X" with the detail
swallowed to stderr, so every handler catches its own errors into an
"ERROR ..." text result). `soffice` must be on PATH - true wherever this
server is registered (both harness feeds put the office CLI set there).

Schema note: the framework turns `Literal[...]` into enums and
`Annotated[str, "doc"]` into property descriptions (pydantic-derived).
"""

import os
import subprocess
from typing import Annotated, Literal

from mcp.server import MCPServer

srv = MCPServer(name="documents", version="1")


def _work_root() -> str:
    return os.environ.get("DOCS_WORK_ROOT") or os.path.expanduser("~")


def _resolve(path: str) -> str:
    """Absolute path, refusing anything landing outside the per-agent work root."""
    if not path:
        raise ValueError("empty path")
    ap = os.path.abspath(os.path.expanduser(path))
    root = os.path.realpath(_work_root())
    # realpath on a not-yet-existing file resolves the parents, which is what
    # matters: no symlink may smuggle the write outside the jail.
    r = os.path.realpath(ap)
    if r != root and not r.startswith(root + os.sep):
        raise ValueError(f"path escapes the work root {root}: {path}")
    return ap


def _parse_range(spec: str, n: int):
    pages = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            pages.extend(range(int(a), int(b) + 1))
        else:
            pages.append(int(part))
    return [p for p in pages if 1 <= p <= n]


@srv.tool(
    name="doc_extract",
    description=(
        "Extract a document to markdown text: PDF (pymupdf4llm, tables "
        "optional) or docx/xlsx/pptx (markitdown). Read-only."
    ),
)
def doc_extract(path: Annotated[str, "source file"], tables: bool = False) -> str:
    try:
        ap = _resolve(path)
        if ap.lower().endswith(".pdf"):
            import pymupdf4llm

            return pymupdf4llm.to_markdown(ap, show_tables=bool(tables))
        from markitdown import MarkItDown

        return MarkItDown().convert(ap).text_content
    except Exception as e:  # noqa: BLE001
        return f"ERROR {type(e).__name__}: {e}"


@srv.tool(
    name="pdf_info",
    description="PDF facts as JSON: page count, metadata, AcroForm field names/types/values.",
)
def pdf_info(path: Annotated[str, "the PDF"]) -> str:
    import json

    try:
        import pymupdf as fitz

        ap = _resolve(path)
        doc = fitz.open(ap)
        fields = []
        for page in doc:
            for w in page.widgets() or []:
                fields.append(
                    {
                        "name": w.field_name,
                        "type": w.field_type_string,
                        "value": w.field_value,
                        "page": page.number + 1,
                    }
                )
        out = {"pages": doc.page_count, "metadata": {k: v for k, v in (doc.metadata or {}).items() if v}, "fields": fields}
        doc.close()
        return json.dumps(out, ensure_ascii=False, default=str)
    except Exception as e:  # noqa: BLE001
        return f"ERROR {type(e).__name__}: {e}"


@srv.tool(
    name="pdf_pages",
    description=(
        "Page surgery, writing a NEW file: mode=extract keeps page_range, "
        "mode=drop deletes it, mode=rotate turns every page rotate_all degrees. "
        "page_range is 1-based pdf pages like '1-3,7'."
    ),
)
def pdf_pages(
    path: str,
    out_path: str,
    mode: Literal["extract", "drop", "rotate"],
    page_range: str = "",
    rotate_all: Literal[0, 90, 180, 270] = 90,
) -> str:
    import json

    try:
        import pypdf

        ap = _resolve(path)
        op = _resolve(out_path)
        r = pypdf.PdfReader(ap)
        n = len(r.pages)
        writer = pypdf.PdfWriter()
        if mode == "extract":
            idx = _parse_range(page_range, n) or list(range(1, n + 1))
        elif mode == "drop":
            drop = set(_parse_range(page_range, n))
            idx = [p for p in range(1, n + 1) if p not in drop]
        else:
            idx = list(range(1, n + 1))
        for p in idx:
            pg = r.pages[p - 1]
            if mode == "rotate":
                pg.rotate(int(rotate_all))
            writer.add_page(pg)
        os.makedirs(os.path.dirname(op) or ".", exist_ok=True)
        with open(op, "wb") as fh:
            writer.write(fh)
        return json.dumps({"out": op, "pages": len(idx)})
    except Exception as e:  # noqa: BLE001
        return f"ERROR {type(e).__name__}: {e}"


@srv.tool(name="pdf_merge", description="Merge PDFs in order into a new file.")
def pdf_merge(paths: list[str], out_path: str) -> str:
    import json

    try:
        import pypdf

        op = _resolve(out_path)
        writer = pypdf.PdfWriter()
        for p in paths:
            for pg in pypdf.PdfReader(_resolve(p)).pages:
                writer.add_page(pg)
        os.makedirs(os.path.dirname(op) or ".", exist_ok=True)
        with open(op, "wb") as fh:
            writer.write(fh)
        return json.dumps({"out": op, "pages": len(writer.pages)})
    except Exception as e:  # noqa: BLE001
        return f"ERROR {type(e).__name__}: {e}"


@srv.tool(
    name="form_fill",
    description="Fill AcroForm text fields from a {field: value} map; writes out_path. Call pdf_info first for field names.",
)
def form_fill(path: str, out_path: str, values: dict[str, str]) -> str:
    import json

    try:
        import pypdf

        ap = _resolve(path)
        op = _resolve(out_path)
        r = pypdf.PdfReader(ap)
        if not r.is_form_pdf:
            return "ERROR not an AcroForm PDF (no form fields; see pdf_info)"
        w = pypdf.PdfWriter(clone_from=r)
        for pg in w.pages:
            w.update_page_form_field_values(pg, values, auto_regenerate=False)
        os.makedirs(os.path.dirname(op) or ".", exist_ok=True)
        with open(op, "wb") as fh:
            w.write(fh)
        return json.dumps({"out": op, "filled": sorted(values)})
    except Exception as e:  # noqa: BLE001
        return f"ERROR {type(e).__name__}: {e}"


@srv.tool(
    name="office_convert",
    description=(
        "Convert with headless LibreOffice (doc->docx, docx->pdf, xlsx->pdf, "
        "pptx->pdf, ods->xlsx, ...). out_path defaults to the input's stem with "
        "the target extension, next to the input (or under out_dir)."
    ),
)
def office_convert(path: str, to: Annotated[str, "target extension, e.g. 'pdf'"], out_dir: str = "") -> str:
    import json

    try:
        ap = _resolve(path)
        od = _resolve(out_dir) if out_dir else os.path.dirname(ap)
        os.makedirs(od, exist_ok=True)
        home = _work_root()
        env = dict(
            os.environ,
            HOME=home,
            XDG_CACHE_HOME=os.path.join(home, ".cache"),
            XDG_CONFIG_HOME=os.path.join(home, ".config"),
            XDG_DATA_HOME=os.path.join(home, ".local/share"),
        )
        cp = subprocess.run(
            ["soffice", "--headless", "--convert-to", str(to), "--outdir", od, ap],
            env=env,
            timeout=300,
            capture_output=True,
            text=True,
        )
        if cp.returncode != 0:
            return f"ERROR soffice exit {cp.returncode}:\n{cp.stdout}\n{cp.stderr}"
        ext = str(to).split(":", 1)[0]
        out = os.path.join(od, os.path.splitext(os.path.basename(ap))[0] + "." + ext)
        return json.dumps({"out": out, "exists": os.path.exists(out), "log": cp.stdout.strip()})
    except Exception as e:  # noqa: BLE001
        return f"ERROR {type(e).__name__}: {e}"


if __name__ == "__main__":
    srv.run("stdio")
