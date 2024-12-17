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
    };
    networking.search = ["airlab"];
    programs.zsh.enable = true;
    programs.kdeconnect.enable = true;
    programs.nix-ld.enable = true;
    #programs.nix-ld.dev.enable = true;

    home-manager = {
      useGlobalPkgs = true;
      users.akos = import ./home.nix inputs;
    };

    MODULES = {
      fonts.nerdfonts.enable = true;
      games.steam.enable = true;
      system.binbash.enable = true;
      system.bluetooth.enable = true;
      system.sound.enable = true;
      virtualisation.docker.enable = true;
      virtualisation.virtualbox.enable = true;
      wm.dwm.enable = true;
      hardware.perifirals.mice.razer.enable = true;
      hardware.perifirals.keyboards.kanata.enable = true;
    };

    environment.systemPackages = with pkgs; [
      my-nixvim.packages.${system}.default
      # helpful tools
      starship
      ripgrep
      httm
      mpv
      tmux
      fd
      fzf
      rsync
      htop
      btop
      neofetch
      cowsay
      graphviz
      devcontainer

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
      curlpp
      libcpr
      ffmpeg
      zip
      unzip
      killall
      bc
      fuse
      wireguard-tools
      sanoid
      pkg-config
      sops

      # typst
      pkgs-unstable.typst
      pkgs-unstable.typstfmt
      pkgs-unstable.prettypst

      # markdown
      marksman
      marp-cli

      # python
      #(python312.withPackages (ps:
      #  with ps; [
      #    pip
      #    jedi-language-server
      #    gitpython
      #    # jupytext
      #    # jupyter-console
      #    # jupyter
      #    numpy
      #    pandas
      #    # scipy
      #    # (opencv4.override {
      #    #   enableGtk3 = true;
      #    #   enableGtk2 = true;
      #    #   enablePython = true;
      #    #   enableCuda = true;
      #    #   enableUnfree = true;
      #    # })
      #  ]))

      # jupyer
      (python311.withPackages (ps:
        with ps; [
          pip
          jedi-language-server
          gitpython
          numpy
          pandas
          matplotlib
          scipy
          pandoc
          nbconvert
          jupyter
          seaborn
        ]))

      # git
      gitFull
      act
      gh
      subversion

      # c++
      gcc
      clang-tools
      gnumake
      cmake

      #rust
      llvmPackages.libclang
      llvm
      rustup
      libclang
      ninja
      vcpkg
      libconfig
      pkgconf
      rust-bindgen
      rust-cbindgen

      # C#
      omnisharp-roslyn
      csharp-ls

      # POSIX
      shellcheck

      # C#
      dotnetCorePackages.dotnet_8.sdk
      dotnetCorePackages.dotnet_8.runtime
      dotnetCorePackages.dotnet_8.aspnetcore
      dotnet-ef
      icu

      # dev tools
      pkgs-unstable.vscode
      pkgs-unstable.gitkraken
      pkgs-unstable.jetbrains.clion
      pkgs-unstable.jetbrains.datagrip
      pkgs-unstable.jetbrains.dataspell
      pkgs-unstable.jetbrains.idea-ultimate
      pkgs-unstable.jetbrains.pycharm-professional
      pkgs-unstable.jetbrains.rider
      rpi-imager
      gparted
      distrobox
      perf-tools

      # k8s
      kubectl

      # user tools
      networkmanagerapplet
      zotero
      dracula-theme
      keepassxc
      inkscape
      gimp
      pcmanfm
      xfce.thunar
      xfce.thunar-volman
      flameshot
      syncthing
      sxiv
      brave
      kitty
      nitrogen
      signal-desktop
      discord
      libreoffice
      logseq
      freecad
      librecad
      wireshark
      appimage-run
      obs-studio

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
