{
  config,
  pkgs,
  lib,
  pkgs-unstable,
  ...
}: {
  options = {
    USERS.akos.enable = lib.mkOption {
      default = false;
      type = lib.types.bool;
      description = "Enable the user akos";
    };
  };

  config = lib.mkIf config.USERS.akos.enable {
    # The one deliberately-accepted vulnerable pin (2026-10-24 audit #7): logseq's
    # derivation in nixpkgs - stable AND unstable alike - still builds against
    # electron_39, so there is no update path that dodges the annotation; dropping this
    # entry takes logseq (and any other electron_39 app that shows up here) down with an
    # eval error. Everything else audit #7 flagged is gone: the global allowBroken in
    # profiles/global.nix and the allowBroken of flake.nix's pkgs-unstable. Re-check this
    # line whenever logseq's packaging moves to a patched electron.
    nixpkgs.config.permittedInsecurePackages = [
      "electron-39.8.10"
    ];

    services.input-remapper.enable = true;
    services.input-remapper.enableUdevRules = true;

    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      stdenv.cc.cc.lib # libstdc++, libgcc_s
      zlib
      openssl
      icu
      curl
      libunwind
      # add more here if you see "error loading shared library" for something specific
    ];

    users.users.akos = {
      isNormalUser = true;
      shell = pkgs.zsh;
      description = "Papp Akos";
      extraGroups = [
        "dialout"
        "networkmanager"
        "wheel"
        "libvirtd"
        "docker"
        "input"
        "uinput"
        "plugdev"
        "vboxusers"
        "openrazer"
        "scanner"
        "lp"
      ];
      # Was a committed yescrypt hash shared verbatim with root on hp and legion5
      # (2026-10-24 audit #1). The value is a sops secret now, distinct from root's, and the
      # exposed password is rotated. neededForUsers because the users-activation script reads
      # this file before sops' normal activation phase runs. mutableUsers = false means
      # `passwd` does NOT survive a rebuild: rotate by
      #   sops set sops/secrets.yaml '["passwords","akos"]' '"$(mkpasswd -m yescrypt)"'
      # (in this repo, as a recipient) and re-deploying.
      hashedPasswordFile = config.sops.secrets."passwords/akos".path;
      # The herdr HUB's outbound key (hp; private half lives ONLY in sops there, mounted by
      # MODULES.services.herdr.sshKeySecret) is trusted for akos too, because hp's catalog
      # row for this laptop is machines.legion5.user = "akos" (hosts/hp/default.nix): the
      # phone-driven hub must reach akos's herdr server - where this laptop's agents
      # actually live - not root's empty one here. Public half only; same human owns both
      # ends; revocation = delete the line, redeploy.
      openssh.authorizedKeys.keys = [
        (lib.removeSuffix "\n" (builtins.readFile ./herdr-hub.pub))
        (lib.removeSuffix "\n" (builtins.readFile ./herdr-mobile.pub))
      ];
    };
    sops.secrets."passwords/akos" = {
      neededForUsers = true;
      mode = "0400";
    };
    nix.settings.trusted-users = ["akos"];
    programs.zsh.enable = true;
    services.gnome.gnome-keyring.enable = true;

    fonts.packages = with pkgs; [
      noto-fonts
      noto-fonts-color-emoji
    ];

    MODULES = {
      fonts.nerdfonts.enable = true;
      games.steam.enable = true;
      hardware.perifirals.keyboards.kanata.enable = true;
      hardware.perifirals.mice.razer.enable = true;
      hardware.perifirals.mice.openmouse.enable = true;
      networking.usbip.enable = true;
      networking.tuvpn.enable = true;
      system.bluetooth.enable = true;
      system.gpg.enable = true;
      system.pipewire.enable = true;
      security.sops.enable = true;
      # The coding-agent harness set for this user consolidated onto omp ALONE
      # (owner ask 2026-11-19): opencode, pi, kilo, cline, codex, claude-code and
      # amp are retired here. The modules stay (hp enables opencode for root, and
      # blender-mcp feeds every still-enabled harness through the generic
      # mcp.servers options), and herdr gates its per-harness config syncs on each
      # module's `enable`, so the retired ones drop out there automatically. omp
      # covers the whole job: same gateway catalogue and sops keys, modelRoles
      # pin, MCP servers, fallback chains. To bring a harness back, re-add its
      # enable block (git history carries the exact pins and rationale comments).
      # oh-my-pi (pi's fork, `omp`): the same gateway pair through ITS native
      # models.yml - built-in discovery replaces pi's extension (openai-models-list
      # reads omniroute's /v1/models), keys stay out of the store the same way
      # (OMPI_<NAME>_API_KEY env exports by the module's omp wrapper), and the
      # default model is pinned through a PI_CONFIG_FILES settings overlay so
      # omp does not boot on "first model with a valid key" (pi.nix doctrine).
      # Pinned to the GATEWAY route for the fleet default model, not the
      # module's derived futurelab-direct one: omp's provider/id spelling is
      # "omniroute/<gateway model id>", and the gateway lists
      # "futurelab/qwen3.8-flash-next" because omniroute.nix seeds that model
      # row (its discovery-only provider is otherwise inventory-driven).
      # smallModel follows defaultModel by the module's own default.
      services.omp = {
        enable = true;
        users = ["akos"];
        defaultModel = "omniroute/futurelab/qwen3.8-flash-next";
        # The Codex route falls back to the gateway route (omp's
        # retry.fallbackChains, declared 2026-11-10). The direct-futurelab
        # fallback was removed 2026-11-12: on a gateway 429 it retried the
        # SAME upstream whose credentials were cooling down anyway - it only
        # added noise to every rate-limit retry.
        fallbackChains."omniroute/codex/gpt-6.1-sol" = ["omniroute/futurelab/qwen3.8-flash-next"];
      };
      # The document/office capability (modules/services/agent-documents.nix):
      # the office CLI set + pinned python env (docx/xlsx/pdfdo/md2office/
      # soffice/doc2md, the `python`+`office-python` shims) system-wide, the
      # fleet pdf/docx/xlsx/documents skills symlinked into ~/.omp/agent/skills
      # (omp's native user-skills root - verified against omp 18.18.9), and a
      # stdio `documents` MCP server in omp's managed mcp.json. This is the
      # ChatGPT-documents parity layer for omp: create/edit/inspect PDF, Word,
      # Excel without an Office install.
      services.agentDocuments.enable = true;
      # Blender MCP: registers the mcp-for-blender stdio server with every
      # enabled harness (the omp one, since the 2026-11-19 consolidation) and keeps the
      # matching Blender add-on installed + enabled here, where blender is
      # installed (cad block below). Off on hosts without the akos user, so
      # the "blender installed" precondition holds by construction.
      # See modules/services/blender-mcp.nix.
      services.blenderMcp = {
        enable = true;
        users = ["akos"];
      };
      virtualisation.docker.enable = true;
      virtualisation.virtualbox.enable = true;
      wm.niri.enable = true;
      dev.platformio.enable = true;
      dev.md2pdf.enable = true;
    };

    systemd.services.systemd-udev-settle.enable = false;
    systemd.services.NetworkManager-wait-online.enable = false;

    environment.systemPackages = with pkgs; [
      # helpful tools
      starship
      ripgrep
      # omp is installed and configured by MODULES.services.omp (the one
      # interactive harness for this user since 2026-11-19); the retired
      # harnesses' packages left the profile with their enable blocks.
      httm
      mpv
      fd
      fzf
      rsync
      htop
      btop-cuda
      devcontainer
      ncdu
      deploy-rs
      alejandra
      nil
      nixd
      sanoid
      rclone
      # ad-hoc transfer to a machine that isn't a host in this fleet (its own relay
      # otherwise, `--relay`/`--noc` to point it at one of ours over the tailnet).
      pkgs-unstable.croc
      sops
      immich-go
      immich-cli
      # (no bare `md2pdf` here: pkgs.md2pdf is the old Python/WeasyPrint tool
      # without real math rendering; the pandoc+Chromium one is installed via
      # MODULES.dev.md2pdf below)

      # system tools
      libnotify
      usbutils
      sshpass
      sshfs
      lm_sensors
      lsof
      cryptsetup
      openssl
      lz4
      nmap
      iperf2
      netcat
      file
      tree
      dig
      pciutils
      acpi
      wget
      curl
      ffmpeg
      zip
      unzip
      killall
      fuse
      tesseract
      wifi-qr
      openconnect
      networkmanager-openconnect
      oath-toolkit

      (python313.withPackages (
        ps:
          with ps; [
            pdfrw
            pagelabels
            ipykernel
          ]
      ))
      uv

      # git
      gitFull
      git-lfs
      gh

      # dev tools
      pkgs-unstable.foxglove-cli
      pkgs-unstable.foxglove-studio
      pkgs-unstable.rerun
      pkgs-unstable.vscode
      pkgs-unstable.jetbrains.idea
      pkgs-unstable.zed-editor
      pkgs-unstable.github-copilot-cli
      # claude-code itself stays OUT of this list: while MODULES.services.
      # claudeCode was enabled (until the 2026-11-19 harness consolidation) it
      # shipped a bin/claude WRAPPER (gateway env exports) and a plain package
      # here would have shadowed it (home profile precedes the system one).
      # The acp adapter/monitor ride on top of whatever claude is on PATH.
      pkgs-unstable.claude-agent-acp
      pkgs-unstable.claude-monitor
      pkgs-unstable.cursor-cli
      pkgs-unstable.gitkraken
      pkgs-unstable.picocom
      pkgs-unstable.xxd
      pkgs-unstable.rpi-imager
      pkgs-unstable.gparted
      pkgs-unstable.perf-tools
      pkgs-unstable.direnv
      pkgs-unstable.devenv
      pkgs-unstable.devpod
      pkgs-unstable.devpod-desktop
      pkgs-unstable.neovide
      pkgs-unstable.vscode-extensions.vadimcn.vscode-lldb
      pkgs.vscode-extensions.vadimcn.vscode-lldb.adapter
      lldb
      gdb

      #k8s
      pkgs-unstable.kubectl
      pkgs-unstable.k9s

      # user tools
      geogebra6
      zotero
      dracula-theme
      bitwarden-desktop
      syncthing
      discord
      obs-studio
      signal-desktop
      # Electron 42 probes the xdg-desktop-portal Secret API first; portal-gnome only registers
      # it under a GNOME session, so under niri the probe fails and Element refuses to open its
      # keyring-encrypted config ("unsupported keyring"). gnome-keyring's plain Secret Service
      # works here - point Element straight at it. Same fix applies to any other Electron app
      # that shows the dialog: override with commandLineArgs "--password-store=gnome-libsecret".
      (element-desktop.override {commandLineArgs = "--password-store=gnome-libsecret";})
      # The Trilium-vs-Joplin comparison (hosts/hp + modules/services/joplin.nix) from the
      # desktop side: the native client instead of the streamed web one. Sync target is
      # WebDAV: Options -> Sync -> WebDAV, URL https://webdav.hp/joplin, user akos (SFTPGo;
      # the /joplin virtual folder maps to /var/lib/hermes/joplin hp's container and Hermes
      # share - hosts/hp/default.nix). Batch sync, not live; the phone uses the same URL.
      # (Supersedes the sshfs-mount + File system target this line used to document: WebDAV
      # needs no manual mount and reaches the phone too.)
      # pkgs-unstable is load-bearing, not hygiene: the 26.05 input's 3.5.13 REFUSES to sync
      # against a target any 3.7-era client touched ("please upgrade your application to
      # version 3.7.0+" - legion5, 2026-10-29), and pinned unstable carries 3.7.21 - exactly
      # hp's container image version (joplin.nix's pin), so client and server share one sync
      # format. `joplin` is NOT it - that is the CLI client.
      pkgs-unstable.joplin-desktop
      logseq
      obsidian
      onlyoffice-desktopeditors
      libreoffice
      pear-desktop
      freerdp
      sxiv
      kitty
      nautilus
      transmission-remote-gtk
      thunderbird
      # XMPP desktop client for akos@akosp.app (Prosody on hp, modules/services/xmpp.nix):
      # nbxmpp does XEP-0156 host-meta discovery + the wss://xmpp.akosp.app/xmpp-websocket
      # transport the tunnel serves, i.e. the exact path xmpp-check validates; also the
      # OMEMO-capable reference for the phone (Conversations/Cheogram).
      gajim

      # cad tools
      freecad
      librecad
      blender

      # browsers
      # firefox comes from programs.firefox below (its policies.json needs the module's wrapper).
      brave

      # network tools
      wireshark
      burpsuite
      networkmanagerapplet

      # graphics tools
      inkscape
      gimp
      krita
    ];

    # perf
    boot.extraModulePackages = [pkgs.perf];

    # qemu
    boot.binfmt.emulatedSystems = ["aarch64-linux"];

    MODULES.networking.netbird.enable = true;

    # Brave and Firefox do their own DNS resolution and bypass systemd-resolved - Firefox with
    # its built-in DoH (default: maximal), Brave with "Use secure DNS" - so both get a public
    # NXDOMAIN for the internal robo4you.at views (e.g. grafana.futurelab.robo4you.at) while
    # every CLI tool resolves fine. Firefox keeps DoH but excludes the zone, so those names fall
    # back to the system resolver; Chromium has no per-domain DoH exclusion, so Brave's secure
    # DNS and built-in client are switched off and it uses getaddrinfo like everything else.
    # Verify after a switch at brave://policy and about:support (or about:policies).
    programs.firefox = {
      enable = true;
      policies.DNSOverHTTPS = {
        Enabled = true;
        ProviderURL = "https://mozilla.cloudflare-dns.com/dns-query";
        ExcludedDomains = ["robo4you.at"];
      };
    };
    environment.etc."brave/policies/managed/dns.json".text = builtins.toJSON {
      BuiltInDnsClientEnabled = false;
      DnsOverHttpsMode = "off";
    };
  };
}
