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

  config = let
    # The vLLM chat-template kwargs both gateway spellings of the qwen3.8-flash-next model
    # take, per reasoning_effort level.
    effort = e: {
      chat_template_kwargs = {
        thinking = true;
        reasoning_effort = e;
      };
    };
    variants = {
      # Variants merge over `options`, so "off" has to switch the base thinking flag off too.
      off = {
        enable_thinking = false;
        chat_template_kwargs.thinking = false;
      };
      low = effort "low";
      medium = effort "medium";
      xhigh = effort "xhigh";
    };
    # One catalogue entry for qwen3.8-flash-next, keyed per provider below: "futurelab/..."
    # through the LiteLLM wildcard on hp, the bare name at the futurelab Aqueduct gateway
    # itself (the prefix only exists in litellm.nix's wildcard deployment spelling). Identical
    # bodies, since both are the same model behind two OpenAI-compatible fronts.
    qwenModel = {
      contextLength = 262144;
      outputLength = 32768;
      modalities = {
        input = ["text" "image" "video"];
        output = ["text"];
      };
      options = effort "xhigh";
      inherit variants;
      # Internal gateway: nothing is billed - state 0 instead of letting opencode fall back to
      # a models.dev price for an id it does not know (its cost keys are snake_case).
      cost = {
        input = 0.0;
        output = 0.0;
        cache_read = 0.0;
        cache_write = 0.0;
      };
    };
  in
    lib.mkIf config.USERS.akos.enable {
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
        services.opencode = {
          enable = true;
          # Primary: the LiteLLM gateway on hp - see hosts/hp/default.nix for what's behind it.
          defaultModel = "litellm/futurelab/qwen3.8-flash-next";
          smallModel = "litellm/futurelab/qwen3.8-flash-next";
          providers.litellm = {
            displayName = "LiteLLM (hp)";
            baseURL = "https://litellm.hp/v1";
            apiKeySecret = "opencode/litellm_api_key";
            models = {
              "futurelab/qwen3.8-flash-next" = qwenModel;
            };
          };
          # Backup for when hp is down: the same model straight from the futurelab Aqueduct
          # gateway (the one litellm.nix's futurelabEnable wildcard proxies on hp). No automatic
          # failover in opencode - pick it by hand in the model selector. The bare model id is on
          # purpose: "futurelab/..." is LiteLLM's wildcard spelling, the Aqueduct gateway lists
          # the name without a prefix.
          providers.futurelab = {
            displayName = "FutureLab (Aqueduct)";
            baseURL = "https://futurelab.robo4you.at/v1";
            apiKeySecret = "futurelab_api_key";
            models = {
              "qwen3.8-flash-next" = qwenModel;
            };
          };
        };
        virtualisation.docker.enable = true;
        virtualisation.virtualbox.enable = true;
        wm.niri.enable = true;
        dev.platformio.enable = true;
      };

      systemd.services.systemd-udev-settle.enable = false;
      systemd.services.NetworkManager-wait-online.enable = false;

      environment.systemPackages = with pkgs; [
        # helpful tools
        starship
        ripgrep
        # pi on PATH for interactive use - the same package (same unstable pin) the
        # paseo-machine daemon drives; its litellm model config (~/.pi/agent/models.json)
        # is written at service start by MODULES.services.paseo-machine. opencode comes from
        # MODULES.services.opencode, whose /etc/opencode.json + $OPENCODE_CONFIG already
        # registers the same litellm gateway for the shells.
        pkgs-unstable.pi-coding-agent
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
        sops
        immich-go
        immich-cli
        md2pdf

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
        pkgs-unstable.vscode
        pkgs-unstable.jetbrains.idea
        pkgs-unstable.zed-editor
        pkgs-unstable.github-copilot-cli
        pkgs-unstable.claude-code
        pkgs-unstable.claude-agent-acp
        pkgs-unstable.claude-monitor
        pkgs-unstable.cursor-cli
        pkgs-unstable.gitkraken
        pkgs-unstable.picocom
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

      services.netbird.enable = true;
      services.netbird.clients.default.autoStart = true;
      services.netbird.clients.default.environment.NB_DISABLE_DNS = "true";
      services.netbird.clients.default.config.DisableDNS = true;

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
