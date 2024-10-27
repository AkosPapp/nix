{
  config,
  pkgs,
  lib,
  pkgs-unstable,
  nixpkgs,
  ...
} @ inputs: {
  options = {
    USERS.akos.enable = lib.mkOption {
      default = false;
      type = lib.types.bool;
      description = "Enable the user akos";
    };
  };

  config = 
    lib.mkIf config.USERS.akos.enable {
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
      programs.nix-ld.libraries = with pkgs; [
        # Add any missing dynamic libraries for unpackaged programs
        # here, NOT in environment.systemPackages
      ];

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
        virtualisation.vmware.enable = true;
        virtualisation.virt-manager.enable = true;
        wm.dwm.enable = true;
        hardware.perifirals.mice.razer.enable = true;
      };

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
        btop
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
        zoxide
        lsd

        # typst
        pkgs-unstable.typst
        pkgs-unstable.typstfmt
        pkgs-unstable.prettypst

        # markdown
        marksman
        marp-cli

        # python
        (python312.withPackages (ps:
          with ps; [
            pip
            jedi-language-server
            gitpython
            jupytext
            jupyter-console
            # (opencv4.override {
            #   enableGtk3 = true;
            #   enableGtk2 = true;
            #   enablePython = true;
            #   enableCuda = true;
            #   enableUnfree = true;
            # })
          ]))
        sage
        (opencv.override {
          enableGtk3 = true;
          enableGtk2 = true;
          enablePython = true;
          enableCuda = false;
          enableUnfree = true;
        })

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

        # dev tools
        pkgs-unstable.vscode
        gitkraken
        pkgs-unstable.jetbrains-toolbox
        openjdk17-bootstrap
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
        flameshot
        syncthing
        sxiv
        pinentry
        brave
        firefox
        geckodriver
        kitty
        nitrogen
        whatsapp-for-linux
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

      boot.binfmt.emulatedSystems = ["aarch64-linux"];

      networking.firewall.enable = false;
    };
}
