{ config, pkgs, lib, pkgs-unstable, home-manager, my-nixvim, ... }@inputs: {
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
      hashedPassword =
        "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";
    };
    programs.zsh.enable = true;
    programs.kdeconnect.enable = true;

    home-manager = {
      useGlobalPkgs = true;
      users.akos = import ./home.nix inputs;
    };

    MODULES = {
      fonts.nerdfonts.enable = true;
      games.steam.enable = true;
      system.binbash.enable = true;
      system.bluetooth.enable = true;
      system.gpg.enable = true;
      system.sound.enable = true;
      virtualisation.docker.enable = true;
      virtualisation.virtualbox.enable = true;
      virtualisation.virt-manager.enable = true;
      wm.dwm.enable = true;
      hardware.perifirals.mice.razer.enable = true;
    };

    # Allow unfree packages
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
      # helpful tools
      starship
      ripgrep
      httm
      mpv
      tmux
      zellij
      fd
      fzf
      rsync
      htop
      neofetch
      cowsay
      graphviz

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
      ffmpeg
      zip
      unzip
      killall
      bc
      fuse
      wireguard-tools
      sanoid

      # typst
      pkgs-unstable.typst
      pkgs-unstable.typstfmt
      pkgs-unstable.typst-lsp
      pkgs-unstable.typst-live
      pkgs-unstable.typst-preview
      pkgs-unstable.prettypst
      pkgs-unstable.tinymist
      #tinymist

      # python
      (python311.withPackages (ps:
        with ps; [
          cstruct
          numpy
          pip
          matplotlib
          transforms3d
          cycler
          jedi-language-server
          bpython
          pep8
          notebook
          gitpython
          jupyter
          jupyter-lsp
          jupyterlab
          jupyterlab-lsp
          jupyterlab-server
          jupyter-collaboration
        ]))
      sage

      # git
      gitFull
      act
      gh

      # c++
      gcc
      clang-tools
      gnumake
      cmake
      # rust
      cargo
      cargo-valgrind
      bacon
      clippy
      dprint
      rust-analyzer
      pkgs-unstable.rustc
      # POSIX
      shellcheck
      # dev tools
      vscode
      gitkraken
      jetbrains-toolbox
      openjdk17-bootstrap
      rpi-imager
      gparted
      distrobox
      perf-tools

      # user tools
      networkmanagerapplet
      zotero
      dracula-theme
      keepassxc
      inkscape
      pcmanfm
      flameshot
      syncthing
      sxiv
      pinentry
      brave
      kitty
      nitrogen
      whatsapp-for-linux
      signal-desktop
      discord
      libreoffice
      logseq
      obsidian
      freecad
      librecad
      wireshark

      # qemu
      qemu_full
      qemu-utils
    ];

    # perf
    boot.extraModulePackages = [ config.boot.kernelPackages.perf ];

    boot.binfmt.emulatedSystems =
      [ "aarch64-linux" "armv6l-linux" "armv7l-linux" ];

    networking.firewall.enable = false;

  };

}
