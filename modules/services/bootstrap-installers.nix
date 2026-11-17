# Token-gated curl|bash installers on the public Funnel: the endpoint formerly riding
# the Paseo cockpit (/install/<token>/<name>.sh), kept as its own module because the
# Paseo hub was retired fleet-wide on 2026-11-11 while the installers' doctrine was not
# - an off-tailnet Linux/macOS box gets the fleet's config for a tool by running one
# command whose URL secret is the auth, and no key ever enters the Nix store: the
# stored templates carry $VAR placeholders that envsubst fills from sops at render
# time (the retired implementation's mechanism, kept verbatim).
#
# What the Paseo version ALSO did - the cockpit page, the pairing-link registry, the
# relay - belonged to Paseo, not to this endpoint; consumers here register plain
# scripts and the runbook documents the commands. The first consumer is the omp
# bootstrap (MODULES.services.omp.bootstrap).
#
# Serving shape: a tiny nginx vhost on loopback serves ${webDir}/install/ with
# autoindex off, so a wrong or missing token never names an existing directory (404);
# Traefik's funnel route `/install` exposes it publicly; a oneshot render unit
# re-renders the whole tree at boot/activation and on secret rotation (sops
# restartUnits), so no timer/hash-dance is needed - the inputs are only the templates
# and the secrets.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.MODULES.services.bootstrapInstallers;
  webDir = "/var/lib/bootstrap-installers";
  nginxUrl = "http://127.0.0.1:${toString config.PORTS.bootstrapInstallers}";

  # Every fixed-path file this endpoint serves (publicPath aliases + pages): drives
  # the render loop's target set and the tailnet apex router's rule.
  publicScriptNames = lib.filterAttrs (_: s: s.publicPath != null) cfg.scripts;
  publicPaths =
    (lib.mapAttrsToList (_: s: s.publicPath) publicScriptNames)
    ++ (lib.mapAttrsToList (_: p: p.path) cfg.pages);

  # The envsubst allowlist: every declared secret var (sops-sourced AND file-sourced),
  # the enrollment token itself (a script may embed its own download path, machine.sh-style),
  # shared across scripts - envsubst only expands placeholders a template actually contains,
  # so a script that does not name another consumer's variable cannot pull its value out.
  installerVarsStr = lib.concatStringsSep " " (
    map (v: "$" + v)
    (["BOOTSTRAP_INSTALL_TOKEN"] ++ lib.attrNames cfg.apiKeys ++ lib.attrNames cfg.fileApiKeys)
  );

  # writeShellScript (not a wrapper the unit sources): the SECRETS arrive via the unit's
  # own `set -a; . env` (sops-nix restartUnits gives the boot ordering), matching the
  # retired render unit, because a pre-253 PID1 right after activation silently ignores
  # EnvironmentFile= (measured 2026-10-26).
  render = pkgs.writeShellScript "bootstrap-installers-render" ''
    set -euo pipefail
    umask 027
    rel="${webDir}/releases/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$rel/install/$BOOTSTRAP_INSTALL_TOKEN" "$rel/public"
    ${lib.concatMapStrings
      (n:
        ''
          ${pkgs.gettext}/bin/envsubst '${installerVarsStr}' <${cfg.scripts.${n}.script} \
            >"$rel/install/$BOOTSTRAP_INSTALL_TOKEN/${n}.sh"
          chmod 0644 "$rel/install/$BOOTSTRAP_INSTALL_TOKEN/${n}.sh"
        ''
        # Fixed-path copy (publicPath): same bytes, same key - a tokenless convenience
        # URL for scripts whose embedded key is revocable per the option docs. Files
        # land under $rel/public, the tree the swap symlink points nginx's alias at.
        + lib.optionalString (cfg.scripts.${n}.publicPath != null) ''
          mkdir -p "$rel/public$(dirname '${cfg.scripts.${n}.publicPath}')"
          ${pkgs.gettext}/bin/envsubst '${installerVarsStr}' <${cfg.scripts.${n}.script} \
            >"$rel/public${cfg.scripts.${n}.publicPath}"
          chmod 0644 "$rel/public${cfg.scripts.${n}.publicPath}"
        ''
        + "\n")
      (lib.attrNames cfg.scripts)}
    ${lib.concatMapStrings
      (n:
        ''
          mkdir -p "$rel/public$(dirname '${cfg.pages.${n}.path}')"
          ${pkgs.gettext}/bin/envsubst '${installerVarsStr}' <${cfg.pages.${n}.source} \
            >"$rel/public${cfg.pages.${n}.path}"
          chmod 0644 "$rel/public${cfg.pages.${n}.path}"
        ''
        + "\n")
      (lib.attrNames cfg.pages)}
    # The header-token ACLs (funnel fetches gated by a REQUEST HEADER instead of a URL
    # segment, so the token never lands in any proxy's access log). nginx reads an
    # `include` only at config PARSE, so these are stable files under ${webDir}/acl
    # (NOT release-swapped): the render rewrites them and reloads nginx. The tmpfiles
    # f-rules pre-create every ACL as deny-all BEFORE nginx first parses the config,
    # so the host can boot and nginx can never serve these paths open.
    mkdir -p "${webDir}/acl"
    ${lib.concatMapStrings
      (a:
        ''
          case "${a.var}" in
            *'"'*|*'\'*) echo "bootstrap-installers-render: ${a.name}'s token contains a quote/backslash - unsafe for nginx config" >&2; exit 1 ;;
          esac
          printf 'if ($http_${a.header} != "%s") { return 404; }\n' "${a.var}" \
            > "${webDir}/acl/${a.name}.conf.new"
          chmod 0640 "${webDir}/acl/${a.name}.conf.new"
          mv -f "${webDir}/acl/${a.name}.conf.new" "${webDir}/acl/${a.name}.conf"
        ''
        + "\n")
      # headerTokens all share $BOOTSTRAP_INSTALL_TOKEN + X-Install-Token; every
      # proxy gates on ITS OWN token var ($<tokenVar>, already exported by the
      # unit's env/file-key section) + its own header, so a leaked enrollment token
      # cannot mint, and a leaked script (which knows the MINT token, baked in)
      # cannot fetch other consumers' scripts or use other proxies.
      ((map (n: {
          name = n;
          header = "x_install_token";
          var = "$BOOTSTRAP_INSTALL_TOKEN";
        }) (lib.attrNames cfg.headerTokens))
        ++ (lib.mapAttrsToList (n: p: {
            name = n;
            header = builtins.replaceStrings ["-"] ["_"] p.header;
            # "$" + name, NOT "$$..." or a brace form: the nix indented-string lexer
            # turns any of those into a literal, and the FIRST deploy rendered
            # `2133167{cfg.mintProxy.tokenVar}` into the ACL - bash $$ (the render's
            # PID!) + braces. Measured on hp 2026-11-15; the installer's
            # mintTokenDefault had to be built the same way.
            var = "$" + p.tokenVar;
          })
          cfg.proxies))}
    # Atomic swap; nginx follows the symlink, old trees keep serving until pruned.
    ln -sfn "$rel/install" "${webDir}/install-new"
    mv -Tf "${webDir}/install-new" "${webDir}/install" || { rm -f "${webDir}/install-new"; ln -sfn "$rel/install" "${webDir}/install"; }
    # The public tree swaps right after; a request landing between the two gets the new
    # install tree with the previous public files (same envsubst inputs, so at most one
    # render older - harmless).
    ln -sfn "$rel/public" "${webDir}/public-new"
    mv -Tf "${webDir}/public-new" "${webDir}/public" || { rm -f "${webDir}/public-new"; ln -sfn "$rel/public" "${webDir}/public"; }
    ${lib.optionalString (cfg.headerTokens != {}) ''
      # Pick up rewritten ACLs (include files are only read at config parse). The
      # reload tolerates failure: during the very first activation nginx may not be
      # up yet; tmpfiles already gave it a deny-all stub to boot with.
      systemctl reload nginx 2>/dev/null || true
    ''}
    find "${webDir}/releases" -mindepth 1 -maxdepth 1 -type d | sort | head -n -3 | xargs -r rm -rf
  '';
in {
  options.MODULES.services.bootstrapInstallers = {
    enable = mkEnableOption ''
      the token-gated public installer endpoint: /install/<enrollment-token>/<name>.sh
      on the Traefik Funnel origin (nginx on loopback, autoindex off - a wrong token
      never names an existing directory). Consumers register scripts via `scripts`;
      secrets arrive via `apiKeys` and are envsubst'd from sops at render time, so no
      key enters the Nix store (the retired Paseo cockpit's doctrine, kept verbatim).
    '';

    tokenSecret = mkOption {
      type = types.str;
      default = "paseo/enrollment_token";
      example = "installers/enrollment_token";
      description = ''
        sops key holding the enrollment token (the secret URL segment). The default
        reuses the key the Paseo cockpit installed with - the live secret that survived
        the 2026-11-11 retirement; point this at a freshly minted key when the paseo/*
        secret cleanup lands (rotation = sops edit + switch; old URLs 404).
      '';
    };

    apiKeys = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = {OMPI_OMNIRIBUTE_API_KEY = "omniroute_api_key";};
      description = ''
        Env-var name -> sops key, available as $VAR placeholders to every registered
        script (one root-owned env template; the allowlist is shared but envsubst
        expands only what a template names). Values go to any box that knows the
        enrollment URL - mint them capped on the gateway, never raw upstream keys.
        A var must be named in exactly one of `apiKeys`/`fileApiKeys`.
      '';
    };

    fileApiKeys = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = lib.literalExpression ''
        {OMPI_OMNIRIBUTE_API_KEY = config.MODULES.services.omniroute.keys.ompBootstrap.filePath;}
      '';
      description = ''
        Env-var name -> path of a file whose (single-line) content is the value - the
        sibling of `apiKeys` for values that are NOT sops material: the nix-minted
        per-service OmniRoute keys under /var/lib/omniroute/keys (audit #7, 2026-11-14)
        land exactly there, and a gateway host can ship each installer its own key with
        no sops entry at all. The render unit (root) cats the file at render time; a
        missing file FAILS the render loudly (the mint unit owns creating it - after the
        first switch that mints, re-run the switch or `systemctl start
        bootstrap-installers-render`). Rotation = the mint re-mints + one re-render;
        already-downloaded scripts keep their old value until a box re-runs the installer.
      '';
    };

    scripts = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          script = mkOption {
            type = types.package;
            description = "Installer script template (a pkgs.writeText'd shell script), served as <attr-name>.sh under the token path.";
          };

          publicPath = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "/install-omp.sh";
            description = ''
              Also serve this script at this FIXED path (exact nginx location), i.e.
              without the enrollment token - the short `curl https://hp/install-omp.sh`
              URL. NO funnel deny is needed for paths outside /install (the funnel
              routes never name them); the tailnet router answers Host(<apex>) on the
              websecure entry point only. The embedded key is then fetchable by anyone
              ON the tailnet, so consumers must point the script's key at a scoped,
              revocable mint (the per-service omniroute keys, audit #7), never a shared
              one. null (default) = token path only, the original behavior.
            '';
          };
        };
      });
      default = {};
      description = "Registered installers: name -> script package.";
    };

    pages = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          source = mkOption {
            type = types.package;
            description = "HTML template (pkgs.writeText); $VAR placeholders expand from the same secret env as the scripts' (incl. $BOOTSTRAP_INSTALL_TOKEN).";
          };

          path = mkOption {
            type = types.str;
            example = "/omp";
            description = "URL the page is served at (exact nginx location, tailnet entry point).";
          };
        };
      });
      default = {};
      description = "Static pages served next to the installers (the homepage tile's target: a page showing the one-liners).";
    };

    headerTokens = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = {omp = "/install-omp.sh";};
      description = ''
        attr name -> file under public/ served at the FIXED funnel path
        /install/<attr-name>.sh, gated by a REQUEST HEADER instead of a URL segment:
        `curl -H "X-Install-Token: <token>" https://<funnel>/install/omp.sh | sh`.
        Why: the URL is what every proxy LOGS (tailscaled, Traefik access logs, any
        intermediate) - a token in the path leaks into all of them; a header does not
        (Traefik's access-log default header mode is drop). The funnel's existing
        /install route lands here, so no new router is needed; the token is the same
        enrollment secret the path scheme uses. The ACL is nginx `if
        ($http_x_install_token != "<token>") { return 404; }` in a rendered include
        (a token NEVER enters the Nix store): the render unit writes it and reloads
        nginx (includes are read at config parse), and tmpfiles pre-creates a
        deny-all stub before nginx can first parse the config, so the host boots
        closed. The tailnet apex publicPath locations stay header-less by contrast -
        that face is the tailnet.
      '';
    };

    proxies = mkOption {
      type = types.attrsOf (types.submodule (
        {name, ...}: {
          options = {
            target = mkOption {
              type = types.str;
              example = "http://127.0.0.1:8149";
              description = "The backend, as `host:port` or a full URL (same shape as the funnel routes' `target`). Loopback-only by convention: the gate is this endpoint's funnel reach.";
            };

            tokenVar = mkOption {
              type = types.str;
              default = "BOOTSTRAP_PROXY_TOKEN_" + lib.toUpper name;
              defaultText = lib.literalExpression "BOOTSTRAP_PROXY_TOKEN_<name>";
              description = "Env var (of apiKeys/fileApiKeys) whose VALUE is the header token: envsubst bakes it into the scripts that need it, and the render writes the same value into this proxy's ACL include. One secret, both sides, from the render's own env.";
            };

            header = mkOption {
              type = types.str;
              default = "x-proxy-token";
              example = "x-mint-token";
              description = "Request header the ACL compares (nginx normalizes to lowercase, dashes to underscores).";
            };

            upstreamPath = mkOption {
              type = types.str;
              default = "/";
              example = "/mcp";
              description = ''
                The backend path the proxy forwards to. The public path is ALWAYS
                /install/<name> (under the funnel's /install/ route - no new
                router); a trailing URI on proxy_pass replaces it, so the mint
                daemon (routes /mint) gets /mint and FastMCP (serves /mcp) gets
                /mcp. Query strings are appended by nginx. Measured on hp 2026-11-15:
                a bare target forwarded the PUBLIC path and the mint daemon answered
                "unknown path" - hence this option.
              '';
            };

            hostHeader = mkOption {
              type = types.str;
              default = "$host";
              example = "localhost";
              description = ''
                Value for proxy_set_header Host. Loopback daemons with DNS-rebinding
                protection (the MCP SDK's streamable-HTTP server answers 421 "Invalid
                Host header" for any foreign Host - measured live 2026-11-15) want
                "localhost", which their default allow-list accepts; the public client
                still talks to the funnel name, this rewrite is only hop-local.
              '';
            };

            readTimeout = mkOption {
              type = types.str;
              default = "35s";
              example = "180s";
              description = ''
                proxy_read_timeout for this gate (a string nginx accepts). An OPTION,
                not a line in extraConfig: nginx rejects a duplicate
                proxy_read_timeout outright (measured on hp 2026-11-15 - an extraConfig
                timeout alongside the template's default failed `nginx -t` and rolled
                back the whole switch), so exactly one lives in the location.
              '';
            };

            extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Raw nginx location config appended (e.g. proxy_buffering off) - EXCEPT proxy_read_timeout, which is `readTimeout`.";
            };
          };
        }
      ));
      default = {};
      example = lib.literalExpression ''
        {
          mint = { target = "http://127.0.0.1:''${toString config.PORTS.installerMint}"; tokenVar = "INSTALL_MINT_TOKEN"; header = "x-mint-token"; upstreamPath = "/mint"; };
        }
      '';
      description = "Header-gated loopback backends published under the funnel's /install/ route as /install/<name>.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.MODULES.networking.traefik.enable && config.MODULES.networking.traefik.funnel.enable;
        message = "MODULES.services.bootstrapInstallers.enable needs Traefik with the funnel entry point - the endpoint exists precisely for machines with no Tailscale.";
      }
      {
        assertion = cfg.scripts != {};
        message = "MODULES.services.bootstrapInstallers.enable with no scripts serves nothing - register one via MODULES.services.bootstrapInstallers.scripts or drop the flip.";
      }
      {
        # A var in both maps would render from one and be overwritten by the other
        # (template order decides) - fail eval instead.
        assertion = builtins.intersectAttrs cfg.apiKeys cfg.fileApiKeys == {};
        message = "MODULES.services.bootstrapInstallers: ${toString (builtins.attrNames (builtins.intersectAttrs cfg.apiKeys cfg.fileApiKeys))} is in BOTH apiKeys and fileApiKeys - pick one source per var.";
      }
      {
        # Every proxy's ACL + the scripts' baked header value both read the render's
        # env, which only carries declared vars - an undeclared tokenVar would
        # envsubst to empty (an ACL accepting "" and opening the backend to the
        # world).
        assertion =
          lib.all (v: (cfg.apiKeys ? ${v}) || (cfg.fileApiKeys ? ${v}))
          (lib.mapAttrsToList (_: p: p.tokenVar) cfg.proxies);
        message = "MODULES.services.bootstrapInstallers: a proxies.<name>.tokenVar is not declared in apiKeys (a sops key) or fileApiKeys (a minted file) - the ACL would gate on the empty string.";
      }
    ];

    # No bespoke group: the tree is served to nginx's PRIMARY group, so the worker's
    # cached credentials always fit. (The first shape here used an installers-web group
    # + users.users.nginx.extraGroups - dead in practice: the nginx unit's worker caches
    # its supplementary groups at unit START, and an nginx.conf-unchanged switch never
    # restarts nginx, so the worker kept serving 404 on a correctly-chowned tree while
    # `id nginx` cheerfully listed the group. Measured on hp 2026-11-13.)
    # mdbook.nix enables services.nginx itself; this flip is idempotent and the vhost
    # below is namespaced, so the two coexist on one nginx instance.
    services.nginx.enable = true;

    # 2750, not 0750: the setgid bit makes every release dir the render creates
    # INHERIT the nginx group, so traversal works without any chgrp step racing
    # activation (measured on the hp switch 2026-11-13: the sops restartUnits restart
    # fired mid-activation before /etc/group carried the group, chgrp -R died
    # "invalid group", the tree stayed root:root 0750 and nginx served 404 for a
    # perfectly good file). The Z rule is the belt: tmpfiles runs on EVERY activation
    # (a oneshot whose inputs are unchanged does not restart on switch, so the
    # render's own chgrp could never heal a stale tree).
    systemd.tmpfiles.rules =
      [
        "d ${webDir} 2750 root nginx - -"
        "d ${webDir}/releases 2750 root nginx - -"
        "Z ${webDir} - root nginx - -"
        # headerTokens ACLs (bootstrap-installers headerTokens): the include files live
        # OUTSIDE the release tree (nginx reads includes at config PARSE, so the render
        # rewrites + reloads instead of swapping). nginx's config references them, so
        # they MUST exist when nginx first parses the config - f creates only when
        # missing, exactly what the render's mv wants too) seed a deny-all stub: a host
        # boots closed even if the very first render has not run yet. 2750 (setgid, same
        # doctrine as the releases dir above): the render writes .new files IN THIS DIR
        # and mv's them, so without setgid the ACL lands root:root 0640 and the nginx
        # master (User=nginx) fails `open() ... Permission denied` on every reload -
        # measured on hp 2026-11-15 within the first hour of the feature existing.
        "d ${webDir}/acl 2750 root nginx - -"
      ]
      # `f` takes the line remainder VERBATIM (measured on hp 2026-11-15: quoting it
      # would emit literal quotes into the file) - the deny-all stub nginx parses until
      # the first render writes the real ACL.
      ++ map (n: "f ${webDir}/acl/${n}.conf 0640 root nginx - return 404;")
      (lib.attrNames cfg.headerTokens ++ lib.attrNames cfg.proxies);

    # The token + every consumer's key, placeholders filled by sops at activation; the
    # render unit (root) is the only reader. Restarting it on rotation re-renders the
    # served scripts with the new values.
    sops.templates."bootstrap-installers.env" = {
      owner = "root";
      content =
        lib.concatStringsSep "\n" (
          [
            ''BOOTSTRAP_INSTALL_TOKEN=${config.sops.placeholder."${cfg.tokenSecret}"}''
          ]
          ++ lib.mapAttrsToList
          (v: k: ''${v}=${config.sops.placeholder."${k}"}'')
          cfg.apiKeys
        )
        + "\n";
      restartUnits = ["bootstrap-installers-render.service"];
    };
    # Bare {}: the shared fleet keys (omniroute_api_key...) may already carry an
    # owner/group from a harness module on this host; sops-nix merges the declarations.
    sops.secrets =
      lib.genAttrs
      (lib.unique ([cfg.tokenSecret] ++ lib.attrValues cfg.apiKeys))
      (_: {});

    systemd.services."bootstrap-installers-render" = {
      description = "Render the token-gated installer tree (envsubst from sops)";
      wantedBy = ["multi-user.target"];
      # audit #7: fileApiKeys values are minted by the omniroute seed unit AFTER the gateway
      # container is up; ordering (not Requires - After= against a non-existent unit is a
      # no-op, and a render failure stays loud by design) so a wiped-dataset first boot
      # mints before it renders instead of failing once.
      after = lib.optionals (cfg.fileApiKeys != {}) ["omniroute-seed-providers.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -a
        . ${config.sops.templates."bootstrap-installers.env".path}
        set +a
        ${lib.concatMapStrings
          (v:
            ''
              # File-sourced value (audit #7): the mint unit (or whoever owns the file) must
              # have produced it - fail the render loudly on a missing one, because an empty
              # $VAR would envsubst into a keyless installer that only 401s on the target box.
              # Retry for ~60s (measured on hp 2026-11-14, first switch): sops-nix's template
              # rotation RESTARTS this unit mid-activation, before omniroute-seed-providers
              # has finished booting the gateway container and minted the key - an After=
              # orders the boot-time start, not a restart, and the failed restart rolled the
              # whole switch back. Still loud if the file never appears. (No bash-variable
              # names may be built by ${v} interpolation here: in a nix indented string a
              # bare `$v` interpolates v AND `''${v}` emits literal `${v}`, so an em-dash-
              # free "test $''${v}_ok" silently tests the WRONG name - measured on hp the
              # same day, where such a retry script died instantly. Literal names only.)
              OMPI_FILE_KEY=""
              for _ in $(seq 1 30); do
                OMPI_FILE_KEY="$(cat '${cfg.fileApiKeys.${v}}' 2>/dev/null || true)"
                # An empty read is as broken as a missing one (a minted key is never empty).
                [ -n "$OMPI_FILE_KEY" ] && break
                sleep 2
              done
              if [ -z "$OMPI_FILE_KEY" ]; then
                echo "bootstrap-installers-render: cannot read ${v}'s key file ${cfg.fileApiKeys.${v}}" >&2
                exit 1
              fi
              export ${v}="$OMPI_FILE_KEY"
            ''
            + "\n")
          (lib.attrNames cfg.fileApiKeys)}
        ${render}
        # No chgrp needed: the releases tree is setgid-nginx (tmpfiles above), so every
        # dir/file the render creates inherits the group, and the Z rule heals any tree
        # rendered before that existed.
      '';
    };

    services.nginx.virtualHosts."bootstrap-installers.internal" = {
      default = true;
      listen = [
        {
          addr = "127.0.0.1";
          port = config.PORTS.bootstrapInstallers;
        }
      ];
      # Token IS the path segment; no index anywhere, nothing else served.
      locations =
        {
          "= /install".return = "404";
          "= /install/".return = "404";
          "/install/" = {
            alias = "${webDir}/install/";
            extraConfig = ''
              autoindex off;
              try_files $uri =404;
            '';
          };
          "/" = {
            return = "404";
          };
        }
        // # Fixed-path aliases + pages (publicPath / pages): exact locations, only
        
        # for declared names, so this vhost still serves nothing else. Reached
        # through the tailnet apex router below (Host(hp)); the funnel's /install
        # route never names these paths, and the funnel has no catch-all on hp, so
        # they stay tailnet-only.
        lib.listToAttrs (
          (lib.mapAttrsToList (n: s: {
              name = "= ${s.publicPath}";
              value = {
                alias = "${webDir}/public${s.publicPath}";
                # served for curl|sh: hand it out as plain text, no MIME sniffing
                # (nixpkgs' location schema has no default_type option).
                extraConfig = "default_type text/plain;";
              };
            })
            publicScriptNames)
          ++ (lib.mapAttrsToList (n: p: {
              name = "= ${p.path}";
              value = {
                alias = "${webDir}/public${p.path}";
                # WITHOUT a type, nginx hands the HTML as
                # application/octet-stream and the browser DOWNLOADS the page
                # instead of opening it (owner: "does not open a website",
                # measured https://hp/omp 2026-11-15). Pages are html by
                # contract (the option serves the homepage tile's target).
                extraConfig = "default_type text/html;\n                  charset utf-8;";
              };
            })
            cfg.pages)
          # headerTokens: FIXED funnel paths gated by X-Install-Token (see the
          # option doc; exact locations win over the /install/ prefix above). The
          # ACL is tmpfiles-stubbed deny-all before the first render, and the
          # render rewrites + nginx-reloads on rotation.
          ++ (lib.mapAttrsToList (n: p: {
              name = "= /install/${n}.sh";
              value = {
                alias = "${webDir}/public${p}";
                extraConfig = ''
                  include ${webDir}/acl/${n}.conf;
                  default_type text/plain;
                '';
              };
            })
            cfg.headerTokens)
          # proxies: header-gated loopback backends published at /install/<name>
          # (exact - wins over the /install/ alias above), gated by their own header
          # ACL. Reaching the internet through the SAME funnel /install/ route (no new
          # router); the tailnet apex router does NOT name them, so a proxy is
          # funnel-only, exactly where an off-tailnet device needs it (measured
          # 2026-11-15: a bare proxy_pass target forwarded the PUBLIC path and the
          # backend 404'd, hence upstreamPath - the URI on proxy_pass replaces the
          # matched location, nginx appends the query string).
          ++ (lib.mapAttrsToList (n: p: {
              name = "= /install/${n}";
              value = {
                extraConfig = ''
                  include ${webDir}/acl/${n}.conf;
                  proxy_pass ${
                    if lib.hasPrefix "http://" p.target || lib.hasPrefix "https://" p.target
                    then p.target
                    else "http://${p.target}"
                  }${p.upstreamPath};
                  proxy_set_header Host ${p.hostHeader};
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto $scheme;
                  proxy_read_timeout ${p.readTimeout};
                  ${p.extraConfig}
                '';
              };
            })
            cfg.proxies)
        );
    };

    # The tailnet face: Host(<apex>) = exactly `curl https://hp/<publicPath>` for the
    # owner's documentation. A hand-written router (the step-ca root_ca.crt precedent)
    # because MODULES.networking.traefik.services keys a router by SUBDOMAIN (the
    # catch-all defaultService owns the apex itself, redirecting it). Priority 100
    # beats the defaultService redirect rule's length-derived default. Only exact
    # declared paths - anything else at the apex keeps redirecting to the default
    # service.
    services.traefik.dynamicConfigOptions.http.routers."${config.networking.hostName}-installers-apex" = lib.mkIf (config.MODULES.networking.traefik.enable && publicPaths != []) {
      rule = "Host(`${config.MODULES.networking.traefik.domain}`) && (${lib.concatStringsSep " || " (map (p: "Path(`${p}`)") publicPaths)})";
      entryPoints = ["websecure"];
      service = "bootstrap-installers-apex";
      tls.certResolver = "stepca";
      priority = 100;
    };
    services.traefik.dynamicConfigOptions.http.services."bootstrap-installers-apex".loadBalancer.servers =
      lib.optionals (publicPaths != []) [{url = nginxUrl;}];

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.funnel = {
      enable = true;
      # Public on purpose: this is the only way onto non-tailnet machines; the token in
      # the path is the authentication (and every script's embedded key is a capped
      # gateway key by consumer convention).
      # NOT "/install": Traefik's PathPrefix is a RAW string prefix with no boundary, so
      # PathPrefix("/install") also routes "/install-omp.sh" - measured 2026-11-15: the
      # tailnet publicPath alias was silently public through the funnel, keyless scripts
      # handed to the internet. "/install/" matches the token tree only.
      routes.bootstrap-install = {
        pathPrefix = "/install/";
        target = nginxUrl;
      };
    };
  };
}
