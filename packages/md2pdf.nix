{
  fetchurl,
  runCommand,
  writeShellScriptBin,
  pandoc,
  chromium,
  gnused,
  coreutils,
}:
# md2pdf: Markdown -> PDF with real LaTeX rendering, via
#   pandoc (md -> standalone HTML + MathJax) -> headless Chromium (print-to-pdf).
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
  # rules). Lives in packages/md2pdf.css so it stays editable as plain CSS.
  defaultCss = builtins.toFile "md2pdf.css" (builtins.readFile ./md2pdf.css);
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

          usage() {
            echo "usage: md2pdf [-o out.pdf] [-t title] [-c extra.css]... input.md [out.pdf]" >&2
          }

          src="" title="" out=""
          css_extra=()
          while [ "$#" -gt 0 ]; do
            case "$1" in
              -o) out="''${2?''$0: -o needs an argument}"; shift 2 ;;
              -t) title="''${2?''$0: -t needs an argument}"; shift 2 ;;
              -c) css_extra+=("''${2?''$0: -c needs an argument}"); shift 2 ;;
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
          "$PANDOC" "$src" \
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

          # Fresh --user-data-dir: a running browser would lock the default profile.
          # --no-sandbox: we print a trusted local file and skip the setuid helper.
          # --allow-file-access-from-files: lets the store's MathJax woff fonts load
          # from a file:// page. --virtual-time-budget: headless waits for MathJax to
          # finish typesetting before printing (20 s budget, renders in ~1 s).
          "$CHROMIUM" --headless=new --disable-gpu --no-sandbox \
            --user-data-dir="$tmp/profile" \
            --allow-file-access-from-files --hide-scrollbars \
            --run-all-compositor-stages-before-draw --virtual-time-budget=20000 \
            --no-pdf-header-footer \
            --print-to-pdf="$tmp/out.pdf" \
            "file://$($REALPATH "$tmp/render.html")" >/dev/null 2>&1

          if [ ! -s "$tmp/out.pdf" ]; then
            echo "md2pdf: chromium produced no PDF (render failure?)" >&2
            exit 1
          fi

          "$CP" "$tmp/out.pdf" "$out"
          echo "md2pdf: wrote $out"
  ''
