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
    programs.zsh.enable = true;
    programs.kdeconnect.enable = true;
    programs.nix-ld.enable = true;
    programs.seahorse.enable = true;
    services.gnome.gnome-keyring.enable = true;
    services.flatpak.enable = true;
    xdg.portal.enable = true;
    xdg.portal.config = {
      common = {
        default = [
          "gtk"
        ];
        "org.freedesktop.impl.portal.Secret" = [
          "gnome-keyring"
        ];
      };
    };

    MODULES = {
      fonts.nerdfonts.enable = true;
      games.steam.enable = true;
      hardware.perifirals.keyboards.kanata.enable = true;
      hardware.perifirals.mice.razer.enable = true;
      networking.usbip.enable = true;
      networking.netbird.enable = false;
      system.binbash.enable = true;
      system.bluetooth.enable = true;
      system.gpg.enable = true;
      system.sound.enable = true;
      virtualisation.docker.enable = true;
      #virtualisation.podman.enable = true;
      virtualisation.virt-manager.enable = true;
      virtualisation.virtualbox.enable = true;
      #wm.dwm.enable = true;
      wm.niri.enable = true;
      dev.platformio.enable = true;
    };

    systemd.services.systemd-udev-settle.enable = false;
    systemd.services.NetworkManager-wait-online.enable = false;

    environment.variables = {
      GPU_FLAG = "--device=nvidia.com/gpu=all";
    };

    environment.systemPackages = with pkgs; [
      my-nixvim.packages.${system}.default
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
      sanoid
      rclone
      sops

      # system tools
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
      glib
      wget
      curl
      ffmpeg
      zip
      unzip
      killall
      bc
      fuse
      pkg-config

      python314

      # git
      gitFull
      git-lfs
      gh

      # dev tools
      pkgs-unstable.vscode
      pkgs-unstable.gitkraken
      rpi-imager
      picocom
      gparted
      perf-tools
      direnv

      # arduino
      platformio-core

      # user tools
      geogebra6
      networkmanagerapplet
      zotero
      dracula-theme
      keepassxc
      inkscape
      gimp
      pcmanfm
      flameshot
      syncthing
      sxiv
      brave
      chromium
      firefox
      kitty
      nitrogen
      signal-desktop
      discord
      libreoffice
      logseq
      freecad
      librecad
      wireshark
      burpsuite
      obs-studio
      youtube-music

      # qemu
      qemu_full
      qemu-utils
    ];

    # perf
    boot.extraModulePackages = [config.boot.kernelPackages.perf];

    # qemu
    boot.binfmt.emulatedSystems = ["aarch64-linux"];
  };
}
