{
  fetchurl,
  runCommand,
  writeShellScriptBin,
  pandoc,
  chromium,
  mermaid-cli,
  gnused,
  gnugrep,
  coreutils,
  python3,
  python3Packages,
}:
# md2pdf: Markdown -> PDF with real LaTeX rendering, via
#   [mermaid pre-pass: ```mermaid fences -> mmdc SVGs as <img>] ->
#   pandoc (md -> standalone HTML + MathJax) -> headless Chromium
#   (print-to-pdf) -> pypdf post-passes (trailing-blank trim, outline titles).
#
# A `---` thematic break is a PAGE separator in this pipeline (md2pdf.css:
# break-after: page; owner ask 2026-11-21), and ```mermaid blocks render
# through mermaid-cli as vector SVGs (md2pdf_mermaid.py pre-pass -
# why pre-pass, not inline SVG/filter, is documented in that file). A
# document ending on a separator leaves one blank final page from Chromium;
# md2pdf_trim.py deletes trailing text-free AND drawing-free pages
# (a diagram-only page carries drawing operators and always survives).
#
# Why this pipeline (iteratively verified on legion5 2026-10-27, 111.md's
# worksheet raster-checked page by page):
#  - the pandoc --pdf-engine=xelatex route dies on color emoji and needs a
#    full TeX live for CJK; Chromium renders both through fontconfig as-is.
#  - MathJax (rather than KaTeX or WeasyPrint's MathML) rendered every
#    inline/display block, \mathbb, \tfrac and \Longleftrightarrow correctly.
#
# MathJax is bundled, not CDN-loaded: pandoc's own --mathjax fetches the script
# from jsdelivr at *render* time, so offline runs produce font-less math.
# nixpkgs' `mathjax` is 4.x, where upstream dropped the prebuilt es5 bundle and
# its woff fonts (verified on the 4.1.1 npm tarball: zero font entries), so we
# pin the last self-contained npm release (3.2.2: es5 bundle + 23 woff-v2
# fonts) and load it over file:// with --allow-file-access-from-files.
# Bump by re-hashing https://registry.npmjs.org/mathjax/-/mathjax-<v>.tgz and
# checking es5/output/chtml/fonts/woff-v2/ still exists.
let
  version = "3.2.2";

  mathjaxSrc = fetchurl {
    url = "https://registry.npmjs.org/mathjax/-/mathjax-${version}.tgz";
    hash = "sha256-G5wKHETfhk6RVpBVjnKtucxSAzYNrv04UITO07bGTAk=";
  };

  mathjax = runCommand "mathjax-es5-${version}" {src = mathjaxSrc;} ''
    mkdir -p $out
    tar xzf $src -C $out --strip-components=1 package/es5
  '';

  # Default print stylesheet (A4, page numbers, styled tables, formula break
  # rules). Lives in md2pdf.css so it stays editable as plain CSS.
  defaultCss = builtins.toFile "md2pdf.css" (builtins.readFile ./md2pdf.css);

  # Postprocessor that gives the chromium-generated outline clean bookmark
  # titles (chromium derives them from layout text: wrap spaces vanish,
  # MathJax glyphs contribute nothing; see the header of the .py file).
  outlineTitles = builtins.toFile "outline_titles.py" (builtins.readFile ./outline_titles.py);

  # Mermaid pre-pass: rewrites ```mermaid fences into <img> tags of
  # mmdc-rendered SVGs BEFORE pandoc sees the file (see the .py header for
  # why not a pandoc filter / inline SVG). mmdc's puppeteer launches the
  # nixpkgs chromium wrapper exports (PUPPETEER_EXECUTABLE_PATH); the config
  # passes the same --no-sandbox the print pass needs (no setuid helper in
  # the agent sandboxes, and the input is a trusted local file).
  mermaidPrepass = builtins.toFile "md2pdf_mermaid.py" (builtins.readFile ./md2pdf_mermaid.py);
  mermaidPptr = builtins.toFile "md2pdf-pptr.json" (builtins.toJSON {
    args = ["--no-sandbox" "--disable-gpu"];
  });

  # `---` is a page break now (see md2pdf.css), so a document can end on one
  # and Chromium prints a final EMPTY page; this post-pass trims trailing
  # blanks (text-free AND drawing-free pages only) before the outline pass.
  trimBlank = builtins.toFile "md2pdf_trim.py" (builtins.readFile ./md2pdf_trim.py);
in
  writeShellScriptBin "md2pdf" ''
          set -eu

          PANDOC="${pandoc}/bin/pandoc"
          CHROMIUM="${chromium}/bin/chromium"
          SED="${gnused}/bin/sed"
          MKTEMP="${coreutils}/bin/mktemp"
          RM="${coreutils}/bin/rm"
          CP="${coreutils}/bin/cp"
          REALPATH="${coreutils}/bin/realpath"
          BASENAME="${coreutils}/bin/basename"
          GREP="${gnugrep}/bin/grep"
          HEAD="${coreutils}/bin/head"
          TR="${coreutils}/bin/tr"
          PYTHON="${python3}/bin/python3"
          OUTLINE_TITLES="${outlineTitles}"
          PYPDF="${python3Packages.pypdf}/lib/${python3.libPrefix}/site-packages"
          MERMAID_PREPASS="${mermaidPrepass}"
          MMDC="${mermaid-cli}/bin/mmdc"
          MMDC_PPTR="${mermaidPptr}"
          TRIM_BLANK="${trimBlank}"

          usage() {
            echo "usage: md2pdf [-o out.pdf] [-t title] [-c extra.css]... [--no-probe] [--no-outline] [--no-mermaid] [--strict] input.md [out.pdf]" >&2
          }

          src="" title="" out=""
          css_extra=()
          probe=1 strict=0 outline=1 mermaid=1
          while [ "$#" -gt 0 ]; do
            case "$1" in
              -o) out="''${2?''$0: -o needs an argument}"; shift 2 ;;
              -t) title="''${2?''$0: -t needs an argument}"; shift 2 ;;
              -c) css_extra+=("''${2?''$0: -c needs an argument}"); shift 2 ;;
              --no-probe) probe=0; shift ;;
              --no-outline) outline=0; shift ;;
              --no-mermaid) mermaid=0; shift ;;
              --strict) strict=1; shift ;;
              -h) usage; exit 0 ;;
              -*) echo "md2pdf: unknown option $1" >&2; usage; exit 2 ;;
              *)
                if [ -z "$src" ]; then src="$1"
                elif [ -z "$out" ]; then out="$1"
                else echo "md2pdf: too many arguments" >&2; exit 2
                fi
                shift ;;
            esac
          done

          if [ -z "$src" ] || [ ! -f "$src" ]; then
            echo "md2pdf: no such input file: ''${src:-<none given>}" >&2
            usage
            exit 2
          fi

          # defaults: <basename>.pdf in CWD, title = <basename without extension>
          if [ -z "$out" ]; then
            stem="''$($BASENAME "$src")"
            out="''${stem%.*}.pdf"
          fi
          if [ -z "$title" ]; then
            stem="''$($BASENAME "$src")"
            title="''${stem%.*}"
          fi

          tmp="''$($MKTEMP -d -t md2pdf.XXXXXX)"
          # shellcheck disable=SC2064
          trap "$RM -rf ''$tmp" EXIT

          # Mermaid pre-pass (see md2pdf_mermaid.py): rewrite
          # ```mermaid fences into raw <img> tags of mmdc-rendered SVGs;
          # pandoc then sees plain markdown + raw HTML. A diagram that fails
          # to render degrades to its literal code block (loud on stderr,
          # fatal only with --strict). Without diagrams the pass is a copy.
          pandoc_src="$src"
          if [ "$mermaid" = 1 ]; then
            "$PYTHON" "$MERMAID_PREPASS" "$src" "$tmp/input.md" "$tmp/mermaid" "$MMDC" "$MMDC_PPTR" "$strict" || exit $?
            pandoc_src="$tmp/input.md"
          fi

          # Absolute paths baked in at build time (nix-time ''${mathjax}); the fontURL
          # must be absolute because MathJax's injected @font-face rules resolve
          # against the page (the temp html), not against the script's location.
          cat > "$tmp/mathjax-config.html" <<'MJEOF'
    <script>
      window.MathJax = {
        chtml: { fontURL: "file://${mathjax}/es5/output/chtml/fonts/woff-v2" },
        options: { enableMenu: false }
      };
    </script>
    MJEOF

          css_args=(--css "${defaultCss}")
          for f in "''${css_extra[@]+''${css_extra[@]}}"; do
            css_args+=(--css "$($REALPATH "$f")")
          done

          # --mathjax=URL must stay on the command line even though we load the
          # script ourselves via the URL: its presence is what makes pandoc pass
          # math through as raw TeX spans. Without it (measured with the 26.05
          # pandoc on 2026-10-27) every $...$ goes through texmath for a MathML
          # conversion, and whichever formulas texmath cannot parse - \Longleftrightarrow,
          # \tfrac, ... - leak into the PDF as literal "$\frac{a}{b}$" text.
          "$PANDOC" "$pandoc_src" \
            --standalone \
            --mathjax="file://${mathjax}/es5/tex-mml-chtml.js" \
            --include-in-header "$tmp/mathjax-config.html" \
            "''${css_args[@]}" \
            --metadata "title:$title" \
            --output "$tmp/render.html"

          # Typography: a rendered formula is an atomic inline-block, so a trailing
          # "." "," ";" ":" "!" "?" can be broken onto the next line alone (measured on
          # 111.md 2026-10-27: the opening line orphaned its period). Glue it with an
          # invisible U+2060 WORD JOINER.
          WJ="$(printf '\342\201\240')"
          "$SED" -i "s|</span>\([.,;:!?]\)|</span>$WJ\1|g" "$tmp/render.html"

          # Print-width probe: Chromium silently scales the WHOLE page down when
          # any element is wider than the print column (nowrap MathJax formulas
          # are the usual culprit; measured on UE5 2026-11-16: one 5-equals
          # chain shrank the entire document to 84%, changing even the H1 size,
          # and different files drifted differently). Before printing, render
          # the page at the exact print column width (A4 210mm minus the CSS's
          # 2x18mm margins = 657.6px at 96dpi) and list elements that overflow
          # it. --strict turns the warning into an error (exit 3); --no-probe
          # skips the extra headless pass.
          outline_flag="--generate-pdf-document-outline"
          if [ "$outline" = 0 ]; then outline_flag=""; fi

          if [ "$probe" = 1 ]; then
            cat > "$tmp/probe.js" <<'PEOF'
    <script>
    function md2pdfMeasure() {
      var limit = 657.6;
      // Predicate: only genuinely unbreakable boxes trigger Chromium's
      // shrink-to-fit. Proven on UE5 2026-11-16: display math (nowrap by the
      // print CSS) shrinking whole pages to 84-91% - while long lines inside
      // pre/code printed at FULL scale (the pre's code{white-space:pre-wrap}
      // makes them breakable), so pre/table must NOT be flagged or every
      // script-line snippet would warn falsely.
      var bad = [];
      var els = document.querySelectorAll("body mjx-container[display], body img, body svg");
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (el.closest("#md2pdf-width-probe")) continue;
        if (el.tagName === "MJX-CONTAINER" && el.getAttribute("display") !== "true") continue;
        var w = 0;
        if (el.tagName === "MJX-CONTAINER") {
          var m = el.querySelector("mjx-math");
          w = m ? m.getBoundingClientRect().width : 0;
        } else if (el.tagName === "IMG") {
          w = el.naturalWidth || el.getBoundingClientRect().width;
        } else {
          w = el.getBoundingClientRect().width;
        }
        if (w > limit + 1) {
          bad.push(Math.round(w * 10) / 10 + "px | " + (el.textContent || "").replace(/\s+/g, " ").trim().slice(0, 100));
        }
      }
      var out = document.createElement("pre");
      out.id = "md2pdf-width-probe";
      out.style.cssText = "position:absolute;left:-99999px";
      out.textContent = "<<MD2PDF_BEGIN>>" + bad.join("<<MD2PDF_SEP>>") + "<<MD2PDF_END>>";
      document.body.appendChild(out);
    }
    function md2pdfWhenReady() {
      // pandoc loads MathJax with defer; the startup promise resolves once
      // every formula is typeset. Poll until it exists, then measure on top
      // of it (a fixed setTimeout races the typesetter and measures empty
      // containers; observed on the first probe build).
      if (window.MathJax && MathJax.startup && MathJax.startup.promise) {
        MathJax.startup.promise.then(function () { setTimeout(md2pdfMeasure, 100); });
      } else {
        setTimeout(md2pdfWhenReady, 250);
      }
    }
    setTimeout(md2pdfWhenReady, 50);
    </script>
    PEOF
            # pandoc's HTML ends in </body></html>; a <script> appended after
            # that gets re-parented into the body by the HTML parser (verified
            # 2026-11-16), so a plain concat beats escaping the snippet into
            # a sed replacement.
            cp "$tmp/render.html" "$tmp/render.probed.html"
            cat "$tmp/probe.js" >> "$tmp/render.probed.html"
            "$CHROMIUM" --headless=new --disable-gpu --no-sandbox \
              --user-data-dir="$tmp/probe-profile" \
              --allow-file-access-from-files --hide-scrollbars \
              --window-size=658,1200 --virtual-time-budget=60000 \
              --dump-dom "file://$($REALPATH "$tmp/render.probed.html")" 2>/dev/null \
              > "$tmp/probe-dom.html" || true
            # The probe node holds "&lt;&lt;MD2PDF_BEGIN&gt;&gt;w1px | ...&lt;&lt;MD2PDF_END&gt;&gt;"
            # (dump-dom re-escapes it). Cut it out, decode the entities, split items.
            offenders="$("$TR" '\n' ' ' < "$tmp/probe-dom.html" \
              | "$SED" -n 's/.*id="md2pdf-width-probe"[^>]*>//p' \
              | "$SED" -e 's/&lt;&lt;MD2PDF_BEGIN&gt;&gt;//; s/&lt;&lt;MD2PDF_SEP&gt;&gt;/\n/g; s/&lt;&lt;MD2PDF_END&gt;&gt;.*//' \
                        -e 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g' -e 's/<[^>]*>//g; s/&amp;/\&/g' \
              | "$GREP" -v '^[[:space:]]*$' | "$HEAD" -5 || true)"
            if [ -n "$offenders" ]; then
              echo "md2pdf: WARNING - content wider than the print column (657.6px);" >&2
              echo "md2pdf:   Chromium shrinks the ENTIRE page to fit; fix the items" >&2
              echo "md2pdf:   below (split long formulas with aligned, wrap long code" >&2
              echo "md2pdf:   lines) or pass --no-probe to accept the scaling." >&2
              printf 'md2pdf:   %s\n' "$offenders" >&2
              if [ "$strict" = 1 ]; then
                echo "md2pdf: aborting (--strict)" >&2
                exit 3
              fi
            fi
          fi

          # Fresh --user-data-dir: a running browser would lock the default profile.
          # --no-sandbox: we print a trusted local file and skip the setuid helper.
          # --allow-file-access-from-files: lets the store's MathJax woff fonts load
          # from a file:// page. --virtual-time-budget: headless waits for MathJax to
          # finish typesetting before printing (20 s budget, renders in ~1 s).
          # --generate-pdf-document-outline: turns the document's h1-h6 into a
          # PDF bookmark/outline tree (viewer sidebar) so long solution files
          # are searchable by section; pandoc numbers the headings, no ids needed
          # (verified with chromium 157 on 2026-11-17).
          "$CHROMIUM" --headless=new --disable-gpu --no-sandbox \
            --user-data-dir="$tmp/profile" \
            --allow-file-access-from-files --hide-scrollbars \
            --run-all-compositor-stages-before-draw --virtual-time-budget=20000 \
            --no-pdf-header-footer \
            ''${outline_flag:+$outline_flag} \
            --print-to-pdf="$tmp/out.pdf" \
            "file://$($REALPATH "$tmp/render.html")" >/dev/null 2>&1

          if [ ! -s "$tmp/out.pdf" ]; then
            echo "md2pdf: chromium produced no PDF (render failure?)" >&2
            exit 1
          fi

          "$CP" "$tmp/out.pdf" "$out"

          # Trim the final EMPTY page Chromium prints when the document ends
          # on a `---` page separator (see md2pdf.css + md2pdf_trim.py).
          # BEFORE the outline pass; best-effort like it.
          PYTHONPATH="$PYPDF" "$PYTHON" "$TRIM_BLANK" "$out" || true

          # Replace chromium's mangled bookmark titles with ones derived from
          # the markdown headings (unicode-transliterated math). PYTHONPATH
          # points at the unpacked pypdf wheel dir; the rewrite is best-effort:
          # any failure leaves chromium's outline in place.
          if [ "$outline" = 1 ]; then
            PYTHONPATH="$PYPDF" "$PYTHON" "$OUTLINE_TITLES" "$src" "$out" || true
          fi
          echo "md2pdf: wrote $out"
  ''
