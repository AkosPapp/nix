# Amp (Sourcegraph's agentic coding CLI, `amp`) behind the fleet's OmniRoute
# gateway - the amp twin of modules/services/pi.nix / opencode.nix, adapted to
# the one harness here whose model routing is NOT local config.
#
# How Amp routes models (verified against the 0.0.1794225648-g45053b CLI on
# legion5 2026-11-09 + ampcode.com/docs/customize/model-routing, 2026-10-29
# revision): every thread lives on ampcode.com and MODEL REQUESTS LEAVE FROM
# AMP'S SERVERS ("If your provider or gateway accepts requests only from known
# IP addresses, allow Amp's server IP addresses"). Connections - the "bring
# your own gateway" objects - are stored server-side, encrypted by Amp; there
# is no local connections file to declare (the binary's only local state paths
# are ~/.config/amp/settings.json, secrets.json and box-services.env - grepped
# from the bun ELF 2026-11-09). `amp` without an account is dead on arrival:
# even `model-providers list` fails "Invalid or missing API key. Run 'amp
# login'". So declarative here means three layers:
#   1. settings.json - local, user-writable (amp writes it too), so the fleet
#      deep-merge doctrine (jq *, pi.nix): updates off (the store is read-only),
#      declared MCP servers re-asserted, user keys survive.
#   2. the gateway CONNECTION - reconciled, not rendered: a per-activation
#      oneshot drives `amp config model-providers` (add-router custom-url /
#      edit-router, key via --api-key-file straight from the sops mount) so the
#      gateway connection exists, carries the current key and base URL, and is
#      active. Cloud state cannot be a symlink; reconciliation is the honest
#      declarative equivalent, and the model mapping (which Amp models ride it,
#      and under what provider id) is rendered from cfg.modelMapping.
#   3. the account key itself - AMP_API_KEY exported from sops by the wrapper
#      (pi.nix doctrine). It is an ampcode.com credential: creating its VALUE
#      is a one-time owner step (`sops edit` after minting one at ampcode.com),
#      same manual-key lineage as omniroute's (hosts/hp/default.nix note).
#
# The gateway is OmniRoute (the other harnesses' pick; it was LiteLLM until
# litellm.nix's phase-3 deletion on 2026-11-09): its connections cover every
# model set through ONE HTTPS URL, which is what a single Amp custom-url
# connection can speak (one api-format each; chat-completions here, which every
# connection serves). And the URL must be one AMP'S CLOUD CAN REACH - the
# tailnet names (omniroute.hp) resolve nowhere from ampcode.com, so the default
# is omniroute.nix's public Funnel base (Tailscale Funnel edge = real LE cert,
# any server trusts it; the gateway itself 401s every /v1 request without a
# valid key - measured on the instance 2026-11-09, so the public path cannot
# become an open proxy). If Amp ever
# cannot reach the Funnel (its egress blocklist), pin cfg.baseUrl to an allowed
# ingress instead.
#
# Model token limits: Amp only offers a mapped model in its mode picker when it
# knows the model's limits; for custom-url connections it reads them from the
# endpoint's /models (OmniRoute reports context_length per model) or models.dev.
# What it cannot read, the web Model Metadata Overrides dialog fixes per
# connection (the CLI cannot set those) - a one-time dashboard step for any
# exotic id, documented at cfg.modelMapping.
{
  config,
  lib,
  pkgs,
  nixosConfigurations,
  ...
}: let
  inherit
    (lib)
    mkEnableOption
    mkIf
    mkOption
    literalExpression
    types
    ;

  cfg = config.MODULES.services.amp;

  # The fleet's public gateway base (hosts with omniroute.public.enable), found
  # through the flake's own configs - the service-graph.nix cross-host doctrine
  # (reading another host's option value is eval-only; the Funnel URL is a
  # readOnly derivation of hp's funnel config). Was litellm.public until that
  # gateway's phase-3 deletion (2026-11-09); omniroute.nix carries the public
  # options verbatim.
  publicGatewayHosts =
    lib.filterAttrs (
      _: hc: (hc.config.MODULES.services.omniroute.public.enable or false) && (hc.config.MODULES.networking.traefik.funnel.enable or false)
    )
    nixosConfigurations;

  defaultBaseUrl =
    if publicGatewayHosts == {}
    then null
    else
      builtins.head (
        lib.mapAttrsToList (_: hc: hc.config.MODULES.services.omniroute.public.baseUrl) publicGatewayHosts
      );

  # settings.json fragment: merged (never replacing), user keys survive.
  # NOTE the QUOTED keys: Amp's settings namespace uses literal DOTTED keys
  # ("amp.updates.mode", "amp.mcpServers"), so `amp.mcpServers = x` in Nix is
  # WRONG - it nests {"amp" = {mcpServers = ...}}, which Amp ignores (measured
  # rendering the fragment 2026-11-09). Every key here carries its dots inside
  # the string.
  settingsFragment =
    {
      # The binary comes from the Nix store; self-update must stay off
      # (settings key AND the AMP_SKIP_UPDATE_CHECK env, which Amp's docs say
      # overrides the setting - belt and braces like pi/opencode).
      "amp.updates.mode" = "disabled";
    }
    // lib.optionalAttrs (cfg.mcp.servers != {}) {"amp.mcpServers" = cfg.mcp.servers;};

  ampWrapper = pkgs.writeShellScriptBin "amp" ''
    export AMP_SKIP_UPDATE_CHECK=1
    ${lib.optionalString (cfg.apiKeySecret != null) ''
      export AMP_API_KEY="$(cat ${config.sops.secrets.${cfg.apiKeySecret}.path} 2>/dev/null || true)"
    ''}
    exec ${cfg.package}/bin/amp "$@"
  '';

  # Which mount the connection's key comes from. NOTE the explicit null test:
  # gatewayKeySecret is a defined option, so `cfg.gatewayKeySecret or ...`
  # would NEVER fall through - `or` catches MISSING attrs, not null ones.
  gatewayKeySecret =
    if cfg.gatewayKeySecret != null
    then cfg.gatewayKeySecret
    else cfg.apiKeySecret;

  gatewayKeyMount =
    if cfg.apiKeySecret == null
    then null
    else config.sops.secrets.${gatewayKeySecret}.path;

  # The connection reconciler, as a standalone script run under
  # `runuser -l cfg.secretOwner`: the connections belong to that user's Amp
  # account (and amp's state lands in their home), so exactly one pass per
  # host, not one per cfg.users entry. It exports AMP_API_KEY from the account
  # mount first - the systemd unit's env is bare, so without the export `amp
  # config model-providers` would 401 even with the key configured. Best-effort
  # by design: ampcode.com flakiness must never roll back a switch (deploy-rs
  # confirmTimeout precedent) - failures log, activations pass, the next
  # activation retries. The --json shape of `list` could not be verified
  # without an account (see header), so the lookup parses defensively and ADDS
  # ONLY on a positive read of the list: unparseable output never duplicates a
  # connection. Quoting note: this is a store script, not an inline `sh -c`
  # string - the mapping value ("a -> b" with spaces) and escapeShellArg's own
  # quotes nest safely. null (no account key at all): the unit is mkIf'd off,
  # and mkIf is STRICT in its value, so the script must not exist to be
  # referenced by anything.
  ampConnectionsSync =
    if cfg.apiKeySecret == null
    then null
    else
      pkgs.writeShellScript "amp-connections-sync" ''
        set -u
        accountMount=${config.sops.secrets.${cfg.apiKeySecret}.path}
        if ! test -r "$accountMount"; then
          echo "amp-connections-sync: AMP_API_KEY mount not readable as ${cfg.secretOwner} - skipping (create the sops key '${cfg.apiKeySecret}')."
          exit 0
        fi
        export AMP_API_KEY="$(cat "$accountMount")"
        want=${lib.escapeShellArg cfg.connectionName}
        list="$(amp config model-providers list --json 2>&1)" || {
          echo "amp-connections-sync: amp list failed (no account? network?) - not touching connections:"
          echo "$list"
          exit 0
        }
        if ! printf '%s' "$list" | ${pkgs.jq}/bin/jq -e . >/dev/null 2>&1; then
          echo "amp-connections-sync: unparseable list output - not adding, to avoid duplicates."
          exit 0
        fi
        # The name reaches jq through --arg, NOT interpolated into the program:
        # the program is single-quoted, and an escapeShellArg inside it would
        # close that quote mid-flight (caught by bash -n on the rendered script
        # 2026-11-09).
        id="$(printf '%s' "$list" | ${pkgs.jq}/bin/jq -r --arg want "$want" '
          (if type == "array" then . else (.connections // .modelProviders // .providers // []) end)
          | map(select((.name? // "") == $want))
          | first // empty
          | (.id // .connectionId // .uuid // empty)' 2>/dev/null)"
        if [ -z "$id" ]; then
          amp config model-providers add-router custom-url \
            --name ${lib.escapeShellArg cfg.connectionName} \
            --base-url ${lib.escapeShellArg cfg.baseUrl} \
            --api-format ${lib.escapeShellArg cfg.apiFormat} \
            --api-key-file ${gatewayKeyMount} \
            ${lib.optionalString (cfg.modelMapping != []) "--model-mapping ${lib.escapeShellArg (lib.concatStringsSep "\n" cfg.modelMapping)}"} \
            --active \
            || echo "amp-connections-sync: add-router failed (see above)."
        else
          amp config model-providers edit-router "$id" \
            --base-url ${lib.escapeShellArg cfg.baseUrl} \
            --api-format ${lib.escapeShellArg cfg.apiFormat} \
            --api-key-file ${gatewayKeyMount} \
            ${lib.optionalString (cfg.modelMapping != []) "--model-mapping ${lib.escapeShellArg (lib.concatStringsSep "," cfg.modelMapping)}"} \
            || echo "amp-connections-sync: edit-router failed (see above)."
        fi
      '';
in {
  options.MODULES.services.amp = {
    enable = mkEnableOption ''
      Amp (Sourcegraph's coding agent CLI) with declarative settings.json and a
      per-activation reconciled OmniRoute gateway connection: AMP_API_KEY
      exported from sops by the module's amp wrapper, updates off, MCP servers
      merged, model routing synced via `amp config model-providers`.
    '';

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../packages/amp-cli.nix {};
      defaultText = literalExpression "pkgs.callPackage ../../packages/amp-cli.nix {}";
      description = "amp-cli package the wrapper execs (vendored bun binary; nixpkgs' `amp` is an unrelated vim-like editor).";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["akos"];
      description = "Users whose ~/.config/amp/settings.json is merged and (as secretOwner) whose Amp account carries the reconciled connection.";
    };

    apiKeySecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "amp_api_key";
      description = ''
        sops key holding the ampcode.com API key (Settings -> API keys),
        exported as AMP_API_KEY and used to authorize `amp config
        model-providers` during reconciliation. null (the default) = never
        touch Amp's cloud: amp needs an interactive `amp login` per user and
        the connection unit is not created at all; settings.json and the
        wrapper still apply. The default is null because the key's VALUE is a
        one-time owner step (mint one at ampcode.com, `sops edit` it in under
        sops/ as e.g. amp_api_key, set this option) - the module cannot script
        an account it does not own.
      '';
    };

    apiFormat = mkOption {
      type = types.enum ["chat-completions" "responses" "anthropic-messages" "google-genai"];
      default = "chat-completions";
      description = "The custom-url connection's api-format (Amp appends /chat/completions, /responses, /v1/messages or the genai path to baseUrl); OmniRoute speaks chat-completions.";
    };

    gatewayKeySecret = mkOption {
      type = types.nullOr types.str;
      default = "omniroute_api_key";
      defaultText = literalExpression "\"omniroute_api_key\"";
      example = "amp/omniroute_api_key";
      description = ''
        sops key holding the gateway key the CONNECTION carries (what
        --api-key-file reads and ampcode.com sends as Authorization: Bearer to
        the gateway). Defaults to the shared fleet inference key (it is what
        every harness here uses); a key minted per-service on the OmniRoute
        dashboard is the cheap scoping step, the trilium/hermes pattern. null
        reuses apiKeySecret, which is WRONG for a gateway that needs its own
        key and exists only to keep the option set small.
      '';
    };

    baseUrl = mkOption {
      type = types.nullOr types.str;
      default = defaultBaseUrl;
      defaultText = literalExpression ''
        omniroute.nix's public.baseUrl on the host enabling omniroute.public (via the flake's nixosConfigurations), null when none
      '';
      description = ''
        The OpenAI-compatible base URL Amp's CLOUD connects to (its servers
        originate the requests - a tailnet-only URL is unreachable there, hence
        the Funnel default). Must be HTTPS. null with enable = true fails the
        module assertion: point it at the Funnel (enable omniroute.public on hp)
        or another ingress Amp's egress IPs may reach.
      '';
      example = "https://hp.tail546fb.ts.net:8443/omniroute/v1";
    };

    connectionName = mkOption {
      type = types.str;
      default = "fleet-gateway";
      description = "The Amp connection this module owns by name (list/add/edit match on it).";
    };

    modelMapping = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [
        "*/*"
        "openai/gpt-5.6-sol -> openrouter/openai/gpt-5.6-sol"
      ];
      description = ''
        Lines for the connection's model mapping, NEWLINE-joined onto
        --model-mapping (Amp accepts comma- or newline-separated patterns; the
        newline form is the documented "one pattern per line" grammar verbatim,
        so it is what the CLI receives). Amp syntax: canonical provider/model
        patterns, `-` prefix excludes, `-> id` overrides the provider-side id -
        for the fleet's gateway that id is the OmniRoute model id the gateway
        receives, e.g.
        "openrouter/anthropic/claude-sonnet-4.5" or "futurelab/qwen3.8-flash-
        next". The arrow is only legal on EXACT include lines (wildcards
        reject it). [] leaves the connection's default (all models Amp knows,
        sent under their default ids). Models neither Amp's catalog nor the
        endpoint's /models describes need the web Model Metadata Overrides
        dialog once (the CLI cannot set token limits).
      '';
    };

    mcp.servers = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = {};
      example = {
        blender = {
          command = "mcp-for-blender";
          args = ["--port" "9876"];
        };
      };
      description = ''
        Amp's `amp.mcpServers` settings map (local: command/args/env with
        ''${VAR} substitution; remote: url/headers), deep-merged into every
        managed ~/.config/amp/settings.json at activation (user servers
        survive, declared ones re-asserted). MODULES.services.blender-mcp feeds
        the blender entry.
      '';
    };

    secretOwner = mkOption {
      type = types.str;
      default =
        if cfg.users != []
        then builtins.head cfg.users
        else "root";
      defaultText = literalExpression "the first configured user";
      description = "Owner of the mounted API-key secrets AND the user whose Amp account the reconciled connection lands on; doctrine in modules/services/pi.nix. Must be one of users.";
    };

    secretGroup = mkOption {
      type = types.str;
      default = "users";
      example = "root";
      description = "Group of the mounted provider API-key secrets; see secretOwner.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.users != [];
        message = "MODULES.services.amp.users must name at least one user (settings.json is per-home).";
      }
      {
        assertion = builtins.elem cfg.secretOwner cfg.users;
        message = ''
          MODULES.services.amp.secretOwner "${cfg.secretOwner}" is not in MODULES.services.amp.users:
          the wrapper cats the key mount AS THE INVOKING USER and the reconciler runs as
          secretOwner, so an unreadable mount means an empty AMP_API_KEY (401).
        '';
      }
      {
        # baseUrl is only consulted by the connection sync, which exists only
        # when an account key is configured - without one the module just
        # merges settings.json and demands nothing of the network.
        assertion = cfg.apiKeySecret == null || cfg.baseUrl != null;
        message = ''
          MODULES.services.amp: apiKeySecret is set but baseUrl is null - no host in this flake
          enables MODULES.services.omniroute.public + traefik.funnel, and Amp's cloud cannot reach a
          tailnet-only gateway. Enable the Funnel face on the gateway host or set baseUrl to
          an ingress ampcode.com's egress IPs may reach.
        '';
      }
      {
        # Same secret mounts as the other harness modules; sops-nix mounts each
        # name with one owner, so the modules may not disagree.
        assertion =
          !config.MODULES.services.pi.enable || cfg.secretOwner == config.MODULES.services.pi.secretOwner;
        message = "MODULES.services.amp.secretOwner must equal MODULES.services.pi.secretOwner (both mount gateway API-key secrets).";
      }
      {
        assertion =
          !config.MODULES.services.codex.enable || cfg.secretOwner == config.MODULES.services.codex.secretOwner;
        message = "MODULES.services.amp.secretOwner must equal MODULES.services.codex.secretOwner (both mount gateway API-key secrets).";
      }
    ];

    sops.secrets = lib.genAttrs (lib.filter (s: s != null) [cfg.apiKeySecret cfg.gatewayKeySecret]) (_: {
      owner = cfg.secretOwner;
      group = cfg.secretGroup;
    });

    environment.systemPackages = [ampWrapper];

    # The keyless settings fragment (names paths and env-var names, never
    # secrets); merged per user below.
    environment.etc."amp/settings-managed.json".text = builtins.toJSON settingsFragment;

    # settings.json is app-written (`amp config edit`), so pi.nix's merge
    # doctrine: deep-merge, user keys survive, unparseable files backed up.
    systemd.services.amp-settings-merge = {
      description = "Merge declared amp settings.json (MODULES.services.amp)";
      after = ["local-fs.target" "systemd-tmpfiles-setup.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "amp-settings-merge" ''
          set -eu
          ${lib.concatMapStringsSep "\n" (
              u: let
                home = config.users.users.${u}.home;
                group = config.users.users.${u}.group;
                dir = "${home}/.config/amp";
                target = "${dir}/settings.json";
              in ''
                # ${u}
                mkdir -p "${dir}"
                chown ${u}:${group} "${dir}"
                chmod 0700 "${dir}"
                tmp="$(mktemp)"
                if [ -s "${target}" ] && ! ${pkgs.jq}/bin/jq -e . "${target}" >/dev/null 2>&1; then
                  # Unparseable is not ours to interpret - keep it, start from the fragment.
                  cp -f "${target}" "${target}.amp-nixos-backup"
                  cp /etc/amp/settings-managed.json "$tmp"
                elif [ -s "${target}" ] && ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "${target}" /etc/amp/settings-managed.json >"$tmp"; then
                  :
                else
                  cp /etc/amp/settings-managed.json "$tmp"
                fi
                if cmp -s "$tmp" "${target}" 2>/dev/null; then
                  rm -f "$tmp"
                else
                  install -m 0600 -o ${u} -g ${group} "$tmp" "${target}"
                fi
                rm -f "$tmp"
              ''
            )
            cfg.users}
        '';
      };
    };

    # The cloud-side half: re-assert the gateway connection (key rotation, base
    # URL, mapping) after the merge, best-effort (see ampConnectionsSync
    # header). Runs as the account owner, once per host.
    systemd.services.amp-connections-sync = lib.mkIf (cfg.apiKeySecret != null) {
      description = "Sync the declared Amp model-provider connection (MODULES.services.amp)";
      after = ["local-fs.target" "network-online.target" "sops-nix.target" "amp-settings-merge.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        # root runs runuser (only root may); the script itself then runs as the
        # account owner (a User= here would make runuser fail from a non-root unit).
        ExecStart = "${pkgs.util-linux}/bin/runuser -l ${cfg.secretOwner} -c ${lib.escapeShellArg ampConnectionsSync}";
      };
    };
  };
}
