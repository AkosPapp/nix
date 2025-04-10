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

    MODULES = {
      fonts.nerdfonts.enable = true;
      games.steam.enable = true;
      system.binbash.enable = true;
      system.bluetooth.enable = true;
      system.sound.enable = true;
      virtualisation.docker.enable = true;
      virtualisation.virtualbox.enable = true;
      virtualisation.virt-manager.enable = true;
      wm.dwm.enable = true;
      hardware.perifirals.mice.razer.enable = true;
      hardware.perifirals.keyboards.kanata.enable = true;
    };

    networking.extraHosts = ''
      10.44.0.3 laser.robo4you.at
    '';

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
      tmux
      fd
      fzf
      rsync
      lsyncd
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

      # jupyer
      (python312.withPackages (ps:
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
          scikit-learn
          # (opencv4.override {
          #   enableGtk3 = true;
          #   enableGtk2 = true;
          #   enablePython = true;
          #   enableCuda = true;
          #   enableUnfree = true;
          # })
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
      pkgs-unstable.dotnetCorePackages.dotnet_8.sdk
      pkgs-unstable.dotnetCorePackages.dotnet_8.runtime
      pkgs-unstable.dotnetCorePackages.dotnet_8.aspnetcore
      pkgs-unstable.dotnetPackages.Nuget
      pkgs-unstable.dotnet-ef
      pkgs-unstable.icu

      # nodejs
      nodejs_23

      # java
      adoptopenjdk-icedtea-web

      # dev tools
      pkgs-unstable.vscode
      pkgs-unstable.gitkraken
      pkgs-unstable.jetbrains.clion
      pkgs-unstable.jetbrains.datagrip
      pkgs-unstable.jetbrains.dataspell
      pkgs-unstable.jetbrains.gateway
      pkgs-unstable.jetbrains.idea-ultimate
      pkgs-unstable.jetbrains.pycharm-professional
      pkgs-unstable.jetbrains.rider
      pkgs-unstable.jetbrains.webstorm
      android-studio
      rpi-imager
      picocom
      pkgs-unstable.arduino-ide
      gparted
      perf-tools

      # k8s
      kubectl

      # user tools
      pkgs-unstable.cura-appimage
      anki
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
