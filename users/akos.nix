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
      # The module's default provider catalogue (rendered from
      # modules/services/model-catalog.nix) is exactly what this user wants - the
      # LiteLLM gateway on hp plus the futurelab Aqueduct gateway as backup - so
      # only the model choices are named here.
      services.opencode = {
        enable = true;
        defaultModel = "litellm/futurelab/qwen3.8-flash-next";
        smallModel = "litellm/futurelab/qwen3.8-flash-next";
      };
      # pi for interactive use, fully declarative (the module owns the package too):
      # /etc/pi/models.json is symlinked into ~/.pi/agent with the API keys resolved at
      # run time via pi's "!cat <sops path>" - nothing secret lands in the store or the
      # home - and settings.json is deep-merged with the default model pinned to the
      # litellm gateway (pi would otherwise boot on the alphabetically-first provider,
      # which is the futurelab backup). Same catalogue and sops keys as
      # services.opencode above; replaces the paseo-machine daemon's home writes
      # (legion5 2026-10-29).
      services.pi = {
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
      # pi is installed (same unstable pin) and configured by MODULES.services.pi;
      # opencode comes from MODULES.services.opencode, whose /etc/opencode.json +
      # $OPENCODE_CONFIG registers the same gateways for the shells.
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
