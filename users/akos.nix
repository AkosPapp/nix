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
      hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";
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
        # No local-model provider: opencode here only ever talks to the LiteLLM gateway on hp
        # (https://litellm.hp) - see hosts/hp/default.nix for what's behind it.
        defaultModel = "litellm/futurelab/qwen3.8-flash-next";
        smallModel = "litellm/futurelab/qwen3.8-flash-next";
        providers.litellm = {
          displayName = "LiteLLM (hp)";
          baseURL = "https://litellm.hp/v1";
          apiKeySecret = "opencode/litellm_api_key";
          models = {
            "futurelab/qwen3.8-flash-next" = let
              effort = e: {
                chat_template_kwargs = {
                  thinking = true;
                  reasoning_effort = e;
                };
              };
            in {
              contextLength = 262144;
              outputLength = 32768;
              modalities = {
                input = ["text" "image" "video"];
                output = ["text"];
              };
              options = effort "xhigh";
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
            };
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
