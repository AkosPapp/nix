#!/usr/bin/env python3
"""Rewrite PDF outline (/Bookmark) titles from the markdown source headings.

Why: chromium's --generate-pdf-document-outline names each bookmark from the
heading's *accessible name* computed off layout text fragments. Two artifacts
follow (measured with chromium 157, 2026-11-17, ANA/ue3/73.pdf):
  - spaces that fall at a soft-wrap point vanish: "...und Rechenregeln für
    Reihen" (wrapped after "für") became "...undRechenregeln für Reihen" -
    and an aria-label on the heading does NOT override it (tested);
  - MathJax math contributes nothing usable: "Teil (a): Partialsummen von
    $B$ berechnen" became "Teil (a): Partialsummen von  berechnen" (the CHTML
    glyphs carry no extractable text; \text{...} annotations would leak as raw
    TeX if assistive-math were enabled instead).
The markdown source has both facts perfectly, so convert the headings here
(strip emphasis/links, transliterate inline $...$ math to unicode) and
overwrite the /Title entries of the existing outline tree, in depth-first
document order. Mutation must go through the real object tree
(_root_object["/Outlines"] + /First//Next//children): mutating the dicts of a
pypdf outline walk is lost, PdfWriter rebuilds /Outlines from the tree on
write (verified 2026-11-17).

On any count mismatch the outline is left untouched - wrong titles are worse
than chromium's mangled ones.
"""
import os
import re
import sys

from pypdf import PdfReader, PdfWriter
from pypdf.generic import NameObject, NumberObject, TextStringObject

MACROS = {
    "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
    "to": "→", "rightarrow": "→", "longrightarrow": "⟶", "Rightarrow": "⇒",
    "Longrightarrow": "⟹", "Leftarrow": "⇐", "leftarrow": "←", "mapsto": "↦",
    "iff": "⟺", "Leftrightarrow": "⇔", "implies": "⟹", "infty": "∞",
    "cdot": "·", "vdots": "⋮", "ddots": "⋱", "times": "×", "pi": "π",
    "mu": "μ", "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
    "Delta": "Δ", "varepsilon": "ε", "epsilon": "ε", "varphi": "φ",
    "phi": "φ", "theta": "θ", "lambda": "λ", "Lambda": "Λ", "sigma": "σ",
    "Sigma": "Σ", "sum": "∑", "prod": "∏", "lim": "lim", "equiv": "≡",
    "approx": "≈", "propto": "∝", "mid": "∣", "nmid": "∤", "pm": "±",
    "ldots": "…", "cdots": "⋯", "dots": "…", "prime": "′",
    "langle": "⟨", "rangle": "⟩", "lVert": "‖", "rVert": "‖",
    "lvert": "|", "rvert": "|", "vert": "|", "lVert": "‖",
    "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
    "setminus": "∖", "subset": "⊂", "subseteq": "⊆", "subsetneq": "⊊",
    "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩",
    "in": "∈", "notin": "∉", "ni": "∋", "forall": "∀", "exists": "∃",
    "wedge": "∧", "vee": "∨", "neg": "¬", "land": "∧", "lor": "∨",
    "lnot": "¬", "therefore": "∴", "because": "∵", "circ": "∘",
    "bullet": "•", "ast": "∗", "surd": "√", "qed": "∎",
    "blacksquare": "∎", "square": "□", "aleph": "ℵ", "hbar": "ℏ",
    "dagger": "†", "checkmark": "✓", "ge": "≥", "to": "→",
}
OPS = {"sin", "cos", "tan", "arctan", "arcsin", "arccos", "log", "ln", "exp",
       "max", "min", "sgn", "Re", "Im", "det", "gcd", "dim", "mod", "Span",
       "rank", "tr", "id"}
SUP = {"0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
       "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽",
       ")": "⁾", "n": "ⁿ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "m": "ᵐ", "l": "ˡ",
       "p": "ᵖ", "x": "ˣ", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ",
       "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "y": "ʸ",
       "z": "ᶻ", "N": "ᴺ", "*": "∗"}
SUB = {"0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆",
       "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍",
       ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
       "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ",
       "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"}
BBB = {"R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ",
       "F": "𝔽", "K": "𝕂", "H": "ℍ"}


def scriptify(body, table, marker):
    body = body.strip("{} ")
    if body and all(c in table for c in body):
        return "".join(table[c] for c in body)
    return f"{marker}({body})"


def math_to_text(s):
    s = re.sub(r"\\(?:,|;|!|:)", " ", s)
    s = re.sub(r"\\(?:quad|qquad)\b", " ", s)
    s = re.sub(r"\\(?:left|right|bigl|bigr|Bigl|Bigr|biggl|biggr|Biggl|Biggr)\b", "", s)
    for _ in range(5):  # repeat: \frac{a}{\frac{b}{c}} nests one brace level per pass
        s, n = re.subn(
            r"\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}",
            lambda m: f"({m.group(1)})/({m.group(2)})", s)
        s, n2 = re.subn(
            r"\\[dt]?binom\s*\{([^{}]*)\}\s*\{([^{}]*)\}",
            lambda m: f"({m.group(1)}|{m.group(2)})", s)
        if not n and not n2:
            break
    s = re.sub(r"\\sqrt\s*\[([^\]]*)\]\s*\{([^{}]*)\}", lambda m: f"{m.group(1)}√({m.group(2)})", s)
    s = re.sub(r"\\sqrt\s*\{([^{}]*)\}", lambda m: f"√({m.group(1)})", s)
    s = re.sub(r"\\sqrt\s*([A-Za-z0-9])", lambda m: f"√{m.group(1)}", s)
    s = re.sub(r"\\(?:widehat|hat|overrightarrow|vec)\s*\{([^{}]*)\}", lambda m: m.group(1), s)
    s = re.sub(r"\\(?:overline|bar)\s*\{([^{}]*)\}", lambda m: m.group(1), s)
    s = re.sub(
        r"\\(?:operatorname|text|textrm|textnormal|mathrm|mathbf|mathit|mathsf|mathcal|mbox)\s*\{([^{}]*)\}",
        lambda m: f" {m.group(1)} ", s)
    s = re.sub(r"\\mathbb\s*\{([A-Z])\}", lambda m: BBB.get(m.group(1), m.group(1)), s)
    s = re.sub(r"\^\{([^{}]*)\}", lambda m: scriptify(m.group(1), SUP, "^"), s)
    s = re.sub(r"_\{([^{}]*)\}", lambda m: scriptify(m.group(1), SUB, "_"), s)
    s = re.sub(r"\^([A-Za-z0-9+\-=()])", lambda m: SUP.get(m.group(1), "^" + m.group(1)), s)
    s = re.sub(r"_([A-Za-z0-9+\-=()])", lambda m: SUB.get(m.group(1), "_" + m.group(1)), s)
    def macro(m):
        w = m.group(1)
        if w in OPS:
            return f" {w} "
        return MACROS.get(w, w)
    s = re.sub(r"\\([A-Za-z]+)", macro, s)
    s = (s.replace(r"\{", "{").replace(r"\}", "}").replace(r"\%", "%")
          .replace(r"\&", "&").replace(r"\$", "$").replace(r"\_", "_")
          .replace(r"\#", "#").replace(r"\*", "*"))
    s = re.sub(r"\\(?=\s|$)", " ", s)
    s = re.sub(r"\^\((\w)\)", lambda m: SUP.get(m.group(1), m.group(0)), s)
    s = re.sub(r"_\((\w)\)", lambda m: SUB.get(m.group(1), m.group(0)), s)
    return s


def md_to_bookmark(t):
    t = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", t)  # images
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)   # links
    t = t.replace("`", "")
    t = re.sub(r"\*\*([^*]+)\*\*", r"\1", t)
    t = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"\1", t)
    t = re.sub(r"\\\[|\\\]", " ", t)
    parts = []
    for i, chunk in enumerate(re.split(r"(?<!\\)\$", t)):
        parts.append(math_to_text(chunk) if i % 2 == 1 else chunk)
    t = "".join(parts)
    return re.sub(r"\s+", " ", t).strip()


def outline_items_in_order(root):
    """Bookmark dict objects in document order: /First->/Next siblings, each
    followed by its children (same recursion chromium's writer emits)."""
    out = []
    it = root.get("/First")
    while it is not None:
        d = it.get_object()
        out.append(d)
        out.extend(outline_items_in_order(d))
        it = d.get("/Next")
        it = it.get_object() if it is not None else None
    return out


def promote_title_children(outlines_ref, top):
    """Unwrap the single top-level bookmark (the document's H1 title): its
    children become the root's children, so the sections are the toctree's
    first level. Chromium nests everything under h1; the user wants
    sections/steps only, title not as its own level (2026-11-17)."""
    title_ref = top.raw_get("/First")
    if title_ref is None:
        return
    title = title_ref.get_object()
    last_ref = top.raw_get("/Last")
    if last_ref is None or last_ref.get_object() is not title:
        return  # several top-level items: nothing to unwrap
    first_child = title.raw_get("/First")
    if first_child is None:
        return  # title without sections: leave alone
    top[NameObject("/First")] = first_child
    top[NameObject("/Last")] = title.raw_get("/Last")
    # reparent the whole promoted sibling chain: their parent is now the
    # /Outlines object itself (outlines_ref), not the removed title node.
    c = first_child
    while c is not None:
        cd = c.get_object()
        cd[NameObject("/Parent")] = outlines_ref
        c = cd.raw_get("/Next") if "/Next" in cd else None
        c = c.get_object() if c is not None else None
    count = top.raw_get("/Count") if "/Count" in top else None
    if isinstance(count, int):
        top[NameObject("/Count")] = NumberObject(count - 1)  # title gone


def main():
    md_path, pdf_path = sys.argv[1], sys.argv[2]
    from pypdf import PdfReader, PdfWriter
    from pypdf.generic import NameObject, TextStringObject

    heads, fence = [], False
    for line in open(md_path, encoding="utf-8"):
        if line.startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        m = re.match(r"^(#{1,6}) (.*)$", line)
        if m:
            heads.append(md_to_bookmark(m.group(2)))

    r = PdfReader(pdf_path)
    if not r.outline:
        return 0
    w = PdfWriter(clone_from=r)
    try:
        outlines_ref = w._root_object.raw_get("/Outlines")
    except KeyError:
        return 0
    top = outlines_ref.get_object()
    promote_title_children(outlines_ref, top)
    items = outline_items_in_order(top)
    if len(items) == len(heads) - 1:
        heads = heads[1:]  # chromium omitted the title bookmark
    if len(items) != len(heads):
        print(f"md2pdf: outline title rewrite skipped "
              f"({len(items)} bookmarks vs {len(heads)} md headings)",
              file=sys.stderr)
        return 0
    for d, new in zip(items, heads):
        d[NameObject("/Title")] = TextStringObject(new)
    tmp = pdf_path + ".outline.tmp"
    with open(tmp, "wb") as f:
        w.write(f)
    os.replace(tmp, pdf_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
