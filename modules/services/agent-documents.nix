# The fleet's shared DOCUMENT + OFFICE capability (owner ask 2026-11-20): real
# read/write of PDF, Word (.docx) and Excel (.xlsx) from every agent harness,
# in ONE place - AGENTS.md Rule 2. Two consumers feed off it:
#
#   * omp  - the office CLI set (`docx`, `xlsx`, `pdfdo`, `doc2md`,
#            `md2office`, `office2docx`, the raw env as `office-python`, the
#            soffice wrapper) through environment.systemPackages, the fleet
#            skills pack (pdf/docx/xlsx/documents) symlinked into
#            ~/.omp/agent/skills/ - the fork's NATIVE user-skills root,
#            verified against omp 18.18.9 on legion5 2026-11-20 (a dropped
#            <name>/SKILL.md there lists in `omp skill list`; symlinked dirs
#            included), and a stdio `documents` MCP server (office_mcp.py -
#            the sandboxed structured ops: page surgery, AcroForm fill,
#            LibreOffice conversion, markdown extraction).
#   * Hermes (hp) - the same CLIs through hermes-agent's extraPackages feed
#            (unit PATH + systemPackages), the documents MCP through
#            services.hermes-agent.mcpServers, and the `documents`+`desktop`
#            skills through settings.skills.external_dirs on /etc/hermes-skills.
#            Hermes' OWN bundled `pdf` + `microsoft-office` skills stay and
#            finally WORK on NixOS: they probe
#            `python -c "import docx, pptx, openpyxl"` before falling back to
#            building a Docker-style venv, and this module's `python` shim is
#            exactly that preinstall - the probe hits, the pm fallback (which
#            can never succeed on this distribution, see the flake's
#            hermes-agent input comment) never runs.
#
# Why a python env + CLIs and not only MCP tools: the skills ecosystem is
# written as shell/python recipes, and a capable agent executes those better
# than it drives a narrow tool enum. The MCP server carries only the
# operations worth sandboxing (path jail + fixed shapes); authoring stays CLI.
#
# Why pkgs-unstable for the python env and LibreOffice: stable 26.05 has no
# `libreoffice` attribute at all (only libreoffice-bin 7.6), no
# python3Packages.pymupdf4llm, and a Dec-2024-markitdown; nixpkgs-unstable -
# already a flake-wide specialArg (omp.nix pins its package from it) - carries
# libreoffice-fresh 26.8, markitdown 0.1.8, pymupdf4llm 0.3.4 (all verified
# substitutable on this lock 2026-11-20). One self-contained env on one
# package set beats mixing interpreter generations across two. The stable
# hosts' OWN set is still used for the system python3/other tools; this env is
# interpreter-pinned to unstable's python3 on purpose.
{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}: let
  inherit (lib) literalExpression mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.agentDocuments;

  py = pkgs-unstable.python3;

  # The whole python fact-table lives here; hosts name none of it.
  pythonEnv = py.withPackages (ps: [
    # PDF read/edit/extract
    ps.pymupdf # fitz: text, images, widgets, page raster
    ps.pymupdf4llm # PDF -> markdown (tables)
    ps.pypdf # merge/split/rotate/forms metadata
    ps.pypdfium2 # fast pdf rendering backend
    ps.pdfplumber # table/text extraction
    ps.reportlab # PDF authoring (what Hermes' bundled pdf skill imports)
    ps.pillow # images / OCR preprocessing
    # Office documents
    ps.python-docx # .docx create/edit
    ps.python-pptx # .pptx
    ps.openpyxl # .xlsx create/edit (styles, formulas)
    ps.pandas # dataframe work + CSV/xlsx pivots
    ps.xlsx2csv # xlsx -> csv on one line
    # universal -> markdown (docx/xlsx/pptx/pdf/html/...)
    ps.markitdown
    # the documents MCP server itself
    ps.mcp
  ]);

  # The office env's explicit name EVERYWHERE (skills, docs, scripts): safe in
  # systemPackages because no other package provides bin/office-python.
  officePython = pkgs.writeShellScriptBin "office-python" ''
    exec ${pythonEnv}/bin/python3 "$@"
  '';

  # Hermes' BUNDLED pdf/microsoft-office skills type bare `python`, though -
  # so the HERMES UNITS additionally get a `python` shim (appended to their
  # extraPackages feed below, never to systemPackages): akos's own profile
  # already ships a bin/python jupyter env (users/akos.nix), and a second
  # provider of the same name in one profile is a buildEnv collision that
  # fails the BUILD, not the eval (caught pre-deploy 2026-11-20). The fork's
  # unit PATH (hermes/bash/coreutils/git) has no python, so the shim is the
  # only answer to the probe wherever it lands.
  pythonShim = pkgs.writeShellScriptBin "python" ''
    exec ${pythonEnv}/bin/python3 "$@"
  '';

  # LibreOffice behind a HOME-defining wrapper: `soffice --headless` refuses to
  # run when HOME is unset/unwritable, and its first invocation writes a user
  # profile there (fine in both harness homes - Hermes' HOME is its stateDir,
  # omp runs in the user's home). --norestore stops crashed-instance recovery
  # from hanging a later batch conversion on a dialog; the explicit
  # UserInstallation keys the profile off XDG_CONFIG_HOME so concurrent
  # invocations do not fight over the default one.
  soffice = pkgs.writeShellScriptBin "soffice" ''
    # -env: NOT --env: - LibreOffice 26.x rejects the double-dash form (measured
    # on the 26.8.0.3 wrapped build 2026-11-20: "Error in option --env:UserInstallation").
    exec ${pkgs-unstable.libreoffice}/bin/soffice \
      -env:UserInstallation="file://''${XDG_CONFIG_HOME:-$HOME/.config}/libreoffice-user" \
      --norestore --nologo --nofirststartwizard "$@"
  '';
  libreoffice = pkgs.writeShellScriptBin "libreoffice" ''
    exec ${soffice}/bin/soffice "$@"
  '';

  # author-edit CLIs: thin JSON-op drivers over python-docx / openpyxl /
  # pypdf+fitz. Enough for "create/patch this document" in one command; the
  # skills teach the full-API escape hatch (office-python heredocs) for
  # anything these flags miss.
  docx = pkgs.writeShellScriptBin "docx" ''
    exec ${pythonEnv}/bin/python3 ${./agent-documents/docx_cli.py} "$@"
  '';
  xlsx = pkgs.writeShellScriptBin "xlsx" ''
    exec ${pythonEnv}/bin/python3 ${./agent-documents/xlsx_cli.py} "$@"
  '';
  pdfdo = pkgs.writeShellScriptBin "pdfdo" ''
    exec ${pythonEnv}/bin/python3 ${./agent-documents/pdfdo_cli.py} "$@"
  '';
  doc2md = pkgs.writeShellScriptBin "doc2md" ''
    exec ${pythonEnv}/bin/python3 ${./agent-documents/doc2md_cli.py} "$@"
  '';

  # The reverse direction of doc2md: markdown is the universal authoring
  # surface, so "write me a report" lands as md -> pandoc -> (soffice) -> the
  # office format, without the agent hand-rolling OOXML.
  md2office = pkgs.writeShellScriptBin "md2office" ''
    # usage: md2office IN.md FORMAT   (FORMAT: pdf|docx|odt|rtf|html|tex|epub)
    # For slides/sheets author .pptx/.xlsx with their dedicated CLIs instead.
    set -eu
    in="''$1"; fmt="''$2"
    stem="''${in%.*}"; dir="$(dirname "''$in")"
    case "''$fmt" in
      pdf)
        tmp="''$stem.pandoc.docx"
        ${pkgs.pandoc}/bin/pandoc "''$in" -o "''$tmp"
        # soffice writes ''$stem.pandoc.pdf (it names after the INPUT); the
        # deliverable is ''$stem.pdf - rename, and drop the intermediate docx.
        ${soffice}/bin/soffice --headless --convert-to pdf:writer_pdf_Export --outdir "''$dir" "''$tmp"
        mv -f "''$dir/''$(basename "''$tmp" .docx).pdf" "''$stem.pdf"
        rm -f "''$tmp"
        echo "''$stem.pdf"
        ;;
      docx|odt|rtf|html|tex|epub)
        ${pkgs.pandoc}/bin/pandoc "''$in" -o "''$stem.''$fmt"
        ;;
      *)
        echo "md2office: unsupported format '''$fmt' (pdf|docx|odt|rtf|html|tex|epub)" >&2
        exit 2
        ;;
    esac
  '';

  office2docx = pkgs.writeShellScriptBin "office2docx" ''
    # legacy .doc/.rtf/.odt -> .docx (keeps editing in python-docx possible)
    exec ${soffice}/bin/soffice --headless --convert-to docx --outdir "$(dirname "$1")" "$1"
  '';

  # OCR, pinned-language (the nixpkgs tesseract default is *every* language,
  # ~1 GB of traineddata - same pin doctrine as hermes-agent.nix's
  # ocrLanguages). On hp the hermes module installs the identical derivation
  # via agentTools (same override args, same store path, inert duplicate);
  # on omp hosts this is what puts `tesseract` next to the pdf skills.
  tesseractPinned = pkgs.tesseract.override {
    enableLanguages = cfg.ocrLanguages;
  };

  # Console-script wrappers: pythonEnv's bin/ is NOT on PATH (it would shadow
  # the system python3 with the unstable interpreter), so the two scripts the
  # skills actually invoke get explicit wrappers.
  xlsx2csv = pkgs.writeShellScriptBin "xlsx2csv" ''
    exec ${pythonEnv}/bin/xlsx2csv "$@"
  '';
  markitdown = pkgs.writeShellScriptBin "markitdown" ''
    exec ${pythonEnv}/bin/markitdown "$@"
  '';

  # The office PATH set (systemPackages everywhere; hermes' unit PATH via its
  # extraPackages feed). p7zip/zip/unzip on purpose: .docx/.xlsx ARE zips, so
  # raw XML surgery stays possible when the APIs fall short.
  packages = [
    officePython
    soffice
    libreoffice
    docx
    xlsx
    pdfdo
    doc2md
    md2office
    office2docx
    xlsx2csv
    markitdown
    tesseractPinned
    pkgs.pandoc # md/docx/odt conversion + md tables + --reference-doc templates
    pkgs.p7zip
    pkgs.unzip
    pkgs.zip
  ];

  # The fleet skills pack. ONE source tree (./agent-documents-skills/*),
  # assembled per consumer: omp gets the authoring skills (omp ships no
  # document skills of its own), Hermes keeps its mature bundled pdf /
  # microsoft-office skills and gets only the fleet additions - the tool map
  # (`documents`) and its own workstation manual (`desktop`, fed by
  # hermes-desktop.nix when that is on).
  ompSkills = pkgs.runCommand "omp-document-skills" {} ''
    mkdir -p $out
    for s in documents pdf docx xlsx; do
      cp -r ${./agent-documents-skills}/$s $out/$s
    done
    chmod -R a+rX $out
  '';

  hermesSkills = pkgs.runCommand "hermes-document-skills" {} ''
    mkdir -p $out
    for s in documents${lib.optionalString cfg.hermesDesktopSkill " desktop"}; do
      cp -r ${./agent-documents-skills}/$s $out/$s
    done
    chmod -R a+rX $out
  '';

  officeMcpPython = "${pythonEnv}/bin/python3";
  officeMcpScript = ./agent-documents/office_mcp.py;
  # The script runs from an environment.etc mount (see the single definition at
  # the bottom), NOT from its /nix/store path: both feeds reference it as a
  # plain STRING in a config file (omp's mcp.json, Hermes' config.yaml), and a
  # string reference keeps no GC root - the store copy of a flake path is only
  # realized for the activation that first wrote it, then reclaimed (measured
  # on hp 2026-11-26: `documents` MCP died "can't open file
  # /nix/store/<old-source>/office_mcp.py" days after a deploy-rs GC). The /etc
  # symlink lives in the toplevel closure, same toplevel-closure trick the
  # skills mounts above already use, and survives every switch unchanged.
  officeMcpPath = "/etc/agent-documents/office_mcp.py";

  # Fleet skill names the tmpfiles pass owns (must match the pack): L+
  # replaces exactly these, so a hand-made skill of the user's with any other
  # name survives untouched.
  skillNames = [
    "documents"
    "pdf"
    "docx"
    "xlsx"
  ];
in {
  options.MODULES.services.agentDocuments = {
    enable = mkEnableOption ''
      the shared document/office toolkit for the fleet's agents: a pinned
      python env (pymupdf/pymupdf4llm/pypdf/openpyxl/python-docx/python-pptx/
      markitdown/...), CLI wrappers (python + office-python shims, soffice,
      docx, xlsx, pdfdo, doc2md, md2office, office2docx), the Agent Skills
      pack and a stdio `documents` MCP server, wired into omp (systemPackages
      + ~/.omp/agent/skills + mcp.json) and into Hermes (extraPackages +
      skills.external_dirs + mcpServers)
    '';

    ompUsers = mkOption {
      type = types.listOf types.str;
      default =
        if config.MODULES.services.omp.enable or false
        then config.MODULES.services.omp.users
        else [];
      defaultText = literalExpression "MODULES.services.omp.users when omp is enabled, else []";
      example = ["akos"];
      description = ''
        Users whose ~/.omp/agent/skills gets the fleet skill pack (symlinks,
        re-asserted by an activation tmpfiles pass). The standard setup needs
        nothing here - the default follows the omp module's own users.
      '';
    };

    hermesDesktopSkill = mkOption {
      type = types.bool;
      default = config.MODULES.services.hermes-desktop.enable or false;
      defaultText = literalExpression "MODULES.services.hermes-desktop.enable";
      description = ''
        Ship the `desktop` skill (X display + browser + VNC facts) in the
        Hermes pack. Only useful together with hermes-desktop.nix, hence the
        derived default. The feeds themselves are gated on each harness's own
        enable, not extra knobs: Hermes gets skills.external_dirs ->
        /etc/hermes-skills (the mount lives under /etc because the sandbox's
        TemporaryFileSystem masks /var/lib beyond its stateDir and PrivateTmp
        hides /tmp and /run - /etc is the only fleet-standard read-only
        location the sandbox already sees) plus the `documents` MCP server;
        omp gets the ~/.omp/agent/skills symlinks plus its mcp.json entry.
      '';
    };

    ocrLanguages = mkOption {
      type = types.listOf types.str;
      default = ["eng" "deu"];
      description = ''
        Tesseract languages shipped with the office set. Must include eng;
        pin the rest - the wrapper's unpinned default is every language,
        ~1 GB of traineddata (hermes-agent.nix pins its own copy identically,
        so hp's units get the same store path either way).
      '';
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = packages;
      defaultText = literalExpression "the fleet office CLI set (module body)";
      description = "The office tool set; installed system-wide and fed to hermes-agent's extraPackages (its units' closed PATH). Override to trim.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.all (u: config.users.users ? "${u}") cfg.ompUsers;
        message = "MODULES.services.agentDocuments.ompUsers names a user this host does not define.";
      }
    ];

    environment.systemPackages = cfg.packages;

    # Rendering fonts: LibreOffice PDF conversion and Chromium on the headless
    # desktop both degrade to ugly fallbacks without real families (the
    # bundled PDF export on a fontless box produces visibly broken documents -
    # the whole point is documents that look authored, so the fonts are part
    # of the capability, not a nicety).
    fonts.packages = with pkgs; [
      dejavu_fonts
      liberation_ttf
      noto-fonts
      noto-fonts-color-emoji
    ];

    # --- omp feed: skills pack + documents MCP ----------------------------------------
    # The pack rides exactly like models.yml does (omp.nix): a world-readable
    # environment.etc mount + L+ symlinks from each user's skills dir. The
    # /etc mount is load-bearing beyond tidiness: a tmpfiles rule naming a
    # bare /nix/store path does NOT realize it (rules are plain strings; the
    # toplevel only builds what its options depend on), so the symlink source
    # could be missing at first activation and vanish on GC.
    # ~/.omp/agent/skills/*/SKILL.md is omp's NATIVE user-skills root
    # (measured on omp 18.18.9, 2026-11-20 - discovered through symlinks),
    # so no settings overlay entry is needed; L+ re-asserts exactly the
    # fleet-owned names, so a hand-made skill of the user's survives.
    # (The /etc/agent-skills mount itself is in the single environment.etc
    # definition at the bottom of this config block.)
    systemd.tmpfiles.rules = lib.mkIf (cfg.ompUsers != []) (lib.flatten (
      map (u: let
        home = config.users.users."${u}".home;
        group = config.users.users."${u}".group;
      in
        [
          "d ${home}/.omp 0700 ${u} ${group} -"
          "d ${home}/.omp/agent 0700 ${u} ${group} -"
          "d ${home}/.omp/agent/skills 0700 ${u} ${group} -"
        ]
        ++ map (skill: "L+ ${home}/.omp/agent/skills/${skill} - - - - /etc/agent-skills/${skill}") skillNames)
      cfg.ompUsers
    ));

    MODULES.services.omp.mcp.servers = mkIf config.MODULES.services.omp.enable {
      documents = {
        type = "stdio";
        command = officeMcpPython;
        args = [officeMcpPath];
        timeout = 180000; # a first soffice conversion bootstraps its profile
      };
    };

    # --- Hermes feed (hp) --------------------------------------------------------------
    # PATH: extraPackages lands on both Hermes units' closed PATH and
    # (again) systemPackages - duplicates there are inert. `python` resolves
    # through that unit PATH (systemd's `path =` prepends), which is what the
    # bundled document skills' probe needs. settings merge is recursiveUpdate
    # (the fork's deepConfigType), so these feeds cannot clobber hermes-agent
    # .nix's own settings block.
    MODULES.services.hermes-agent.extraPackages = mkIf config.MODULES.services.hermes-agent.enable cfg.packages;

    # The bare-`python` shim ONLY on the units' PATH (hermes-agent's internal
    # agentToolFeeds -> `path =`): the akos profile already provides
    # bin/python (the jupyter env, users/akos.nix), so a second systemPackages
    # provider would fail the buildEnv, and Hermes' bundled document skills
    # would answer their probe with the jupyter env instead of ours.
    MODULES.services.hermes-agent.agentToolFeeds = mkIf config.MODULES.services.hermes-agent.enable [pythonShim];

    services.hermes-agent.settings = mkIf config.MODULES.services.hermes-agent.enable {
      skills.external_dirs = ["/etc/hermes-skills"];
    };

    services.hermes-agent.mcpServers = mkIf config.MODULES.services.hermes-agent.enable {
      documents = {
        command = officeMcpPython;
        args = [officeMcpPath];
        timeout = 180;
      };
    };

    environment.etc =
      {
        # omp's user-skills mount (world-readable /etc is the toplevel-closure
        # trick described above; see the omp feed comment).
        "agent-skills".source = ompSkills;
        # The documents MCP server script, mounted for BOTH feeds to exec by
        # path (see officeMcpPath above for the GC incident that moved it out
        # of the bare /nix/store flake path).
        "agent-documents/office_mcp.py".source = officeMcpScript;
      }
      // lib.optionalAttrs config.MODULES.services.hermes-agent.enable {
        # ONE environment.etc definition for the whole module: a dotted
        # `etc."x".source` alongside an attrset `etc = {...}` is the
        # "attribute already defined" trap (AGENTS.md), and mkIf on the
        # attrsOf option (not the leaf) keeps the instance out of the
        # collection walk when hermes is off (legion5 eval, 2026-11-20).
        # The flag sits on the attrsOf option per the doctrine in limits.nix's
        # header: `etc."hermes-skills".source = mkIf ...` would still create
        # the submodule instance, and the etc collection then accesses
        # `.source` with no value.
        "hermes-skills".source = hermesSkills;
      };
  };
}
