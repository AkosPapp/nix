{
  config,
  pkgs,
  lib,
  pkgs-unstable,
  nixpkgs,
  my-nixvim,
  ...
} @ inputs: {
  options = {
    USERS.akos.enable = lib.mkOption {
      default = false;
      type = lib.types.bool;
      description = "Enable the user akos";
    };
  };

  config = lib.mkIf config.USERS.akos.enable {
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
      ];
      hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";
      packages = [
        my-nixvim.packages.${pkgs.system}.default
      ];
    };
    nix.settings.trusted-users = ["akos"];
    programs.zsh.enable = true;
    services.gnome.gnome-keyring.enable = true;

    MODULES = {
      fonts.nerdfonts.enable = true;
      games.steam.enable = true;
      hardware.perifirals.keyboards.kanata.enable = true;
      hardware.perifirals.mice.razer.enable = true;
      networking.usbip.enable = true;
      system.bluetooth.enable = true;
      system.gpg.enable = true;
      system.pipewire.enable = true;
      security.sops.enable = true;
      virtualisation.docker.enable = true;
      virtualisation.virt-manager.enable = true;
      virtualisation.virtualbox.enable = true;
      wm.niri.enable = true;
      dev.platformio.enable = true;
    };

    systemd.services.systemd-udev-settle.enable = false;
    systemd.services.NetworkManager-wait-online.enable = false;

    environment.variables = {
      GPU_FLAG = "--device=nvidia.com/gpu=all";
    };

    environment.systemPackages = with pkgs; [
      my-nixvim.packages.${pkgs.system}.default
      # helpful tools
      starship
      ripgrep
      httm
      mpv
      fd
      fzf
      rsync
      lsyncd
      htop
      btop
      devcontainer
      ncdu
      deploy-rs
      alejandra
      nil
      nixd
      sanoid
      rclone
      sops

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
      grim
      slurp
      tesseract

      python314

      # git
      gitFull
      git-lfs
      gh

      # dev tools
      pkgs-unstable.foxglove-studio
      pkgs-unstable.vscode
      pkgs-unstable.copilot-cli
      jetbrains.datagrip
      pkgs-unstable.gitkraken
      #rpi-imager
      picocom
      gparted
      perf-tools
      direnv

      # user tools
      geogebra6
      zotero
      dracula-theme
      bitwarden-desktop
      syncthing
      discord
      obs-studio
      signal-desktop
      logseq
      anki
      libreoffice
      youtube-music
      freerdp
      sxiv
      kitty
      nautilus

      # cad tools
      freecad
      librecad

      # browsers
      brave
      chromium
      firefox

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
    networking.extraHosts = ''
      10.44.0.3 proxmox.robo4you.at
    '';
  };
}
