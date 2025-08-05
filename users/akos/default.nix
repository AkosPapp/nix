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
      networking.netbird.enable = true;
      system.binbash.enable = true;
      system.bluetooth.enable = true;
      system.gpg.enable = true;
      system.sound.enable = true;
      virtualisation.docker.enable = true;
      #virtualisation.podman.enable = true;
      virtualisation.virt-manager.enable = true;
      virtualisation.virtualbox.enable = true;
      wm.dwm.enable = true;
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
      wireguard-tools
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

      # typst
      pkgs-unstable.typst
      pkgs-unstable.typstfmt
      pkgs-unstable.prettypst

      # markdown
      marksman
      marp-cli

      # jupyer
      uv
      (python313.withPackages (ps:
        with ps; [
          autopep8
          pip
          jedi-language-server
          gitpython
          numpy
          pandas
          matplotlib
          scipy
          (mlxtend.overrideAttrs (oldAttrs: {
            disabledTests = [
              # Type changed in numpy2 test should be updated
              "test_invalid_labels_1"
              "test_default"
              "test_nullability"
              "test_verbose"
              "test_classifier_gridsearch"
              "test_train_meta_features_"
              "test_predict_meta_features"
              "test_meta_feat_reordering"
              "test_sparse_inputs"
              "test_sparse_inputs_with_features_in_secondary"
              "test_StackingClassifier_drop_proba_col"
              "test_works_with_df_if_fold_indexes_missing"
              "test_decision_function"
              "test_different_models"
              "test_use_features_in_secondary"
              "test_multivariate"
              "test_multivariate_class"
              "test_internals"
              "test_gridsearch_numerate_regr"
              "test_regressor_gridsearch"
              "test_predict_meta_features"
              "test_train_meta_features_"
              "test_sparse_matrix_inputs"
              "test_sparse_matrix_inputs_with_features_in_secondary"
              "test_sample_weight"
              "test_weight_ones"
              "test_weight_unsupported_with_no_weight"
              "test_EnsembleVoteClassifier"
              "test_EnsembleVoteClassifier_weights"
              "test_EnsembleVoteClassifier_gridsearch"
              "test_string_labels_numpy_array"
              "test_string_labels_python_list"
              "test_StackingClassifier"
              "test_StackingClassifier_proba_avg_"
              "test_StackingClassifier_proba_concat_"
              "test_gridsearch"
              "test_use_probas"
              "test_StackingCVClassifier"
              "test_use_clones"
              "test_no_weight_support_with_no_weight"
              "test_StackingClassifier_proba"
              "test_gridsearch"
              "test_gridsearch_enumerate_names"
              "test_use_probas"
              "test_do_not_stratify"
              "test_cross_validation_technique"
            ];
          }))
          pandoc
          nbconvert
          jupyter
          ipykernel
          pip
          notebook
          nbformat
          nbconvert
          seaborn
          scikit-learn
          (opencv4.override {
            enableGtk3 = true;
            enableGtk2 = true;
            enablePython = true;
            enableCuda = true;
            enableUnfree = true;
          })
          pytesseract
        ]))

      # git
      gitFull
      git-lfs
      gh

      # c++
      gcc
      clang-tools
      gnumake
      cmake

      #rust
      rustup

      # POSIX
      shellcheck

      # C#
      omnisharp-roslyn
      csharp-ls
      pkgs-unstable.dotnetCorePackages.dotnet_8.sdk
      pkgs-unstable.dotnetCorePackages.dotnet_8.runtime
      pkgs-unstable.dotnetCorePackages.dotnet_8.aspnetcore
      pkgs-unstable.dotnetPackages.Nuget
      pkgs-unstable.dotnet-ef
      pkgs-unstable.icu

      # dev tools
      pkgs-unstable.vscode
      pkgs-unstable.gitkraken
      pkgs-unstable.jetbrains.idea-ultimate
      pkgs-unstable.jetbrains.rider
      rpi-imager
      picocom
      gparted
      perf-tools
      direnv

      # arduino
      platformio-core

      # user tools
      geogebra
      geogebra6
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
      firefox
      kitty
      nitrogen
      signal-desktop
      discord
      libreoffice
      logseq
      freecad
      openscad
      openscad-lsp
      librecad
      wireshark
      burpsuite
      obs-studio
      youtube-music

      # qemu
      qemu_full
      qemu-utils

      # openvpn
      networkmanager-openvpn
      openvpn
    ];

    # perf
    boot.extraModulePackages = [config.boot.kernelPackages.perf];

    # qemu
    boot.binfmt.emulatedSystems = ["aarch64-linux"];
  };
}
