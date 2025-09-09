{
  pkgs,
  lib,
  modulesPath,
  pkgs-unstable,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    #(modulesPath + "/profiles/headless.nix")
    #(modulesPath + "/profiles/minimal.nix")
  ];

  config = {
    MODULES.nix.builders.airlab = true;

    networking = {
      firewall.enable = true;
      hostName = "akos01";
      useDHCP = true;
      extraHosts = ''
        127.0.0.1 localhost
      '';
    };

    boot.initrd.availableKernelModules = [
      "uhci_hcd"
      "ehci_pci"
      "ahci"
      "virtio_pci"
      "sr_mod"
      "virtio_blk"
    ];

    # disable useless software
    xdg.icons.enable = false;
    xdg.mime.enable = false;
    xdg.sounds.enable = false;
    hardware.bluetooth.enable = false;

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    powerManagement.cpuFreqGovernor = "performance";
    time.timeZone = "Europe/Vienna";
    #nix.settings.experimental-features = ["nix-command" "flakes"];

    # root user
    users.mutableUsers = false;
    users.users = {
      root = {
        openssh.authorizedKeys.keys = import ./authorized_key.nix;
      };
    };

    # Enable the OpenSSH daemon.
    security.pam.sshAgentAuth.enable = true;
    programs.ssh.forwardX11 = true;
    services.openssh = {
      enable = true;
      settings = {
        X11Forwarding = true;
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };

    system.stateVersion = "25.05";

    systemd.suppressedSystemUnits = [
      "dev-mqueue.mount"
      "sys-kernel-debug.mount"
      "sys-fs-fuse-connections.mount"
    ];

    environment.systemPackages = with pkgs; [
      vim
      git
      dig
      pkgs-unstable.vscode
      pkgs-unstable.code-server
    ];

    users.users.code = {
      isNormalUser = true;
      #shell = pkgs.zsh;
      description = "code";
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
      #hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";
      openssh.authorizedKeys.keys = import ./authorized_key.nix;
    };

    MODULES.virtualisation.docker.enable = true;

    MODULES.networking.tailscale.enable = lib.mkForce true;
    services.tailscale = {
      enable = true;
      openFirewall = true;
      extraSetFlags = lib.mkForce ["--accept-dns=false" "--accept-routes=false" "--advertise-routes=10.50.0.0/23,10.44.0.0/24,172.18.0.0/16"];
      useRoutingFeatures = "both";
    };
    networking.firewall.checkReversePath = "loose";

    services.qemuGuest.enable = true;

    sops.secrets."nix-builder/private_key" = {
      mode = lib.mkForce "0640";
      owner = "hydra";
      group = "hydra";
    };
    services.hydra = {
      enable = true;

      # Network settings
      listenHost = "0.0.0.0"; # Listen on all interfaces
      port = 3000; # Hydra web UI port

      # Package to build; commonly the nixpkgs package set
      package = pkgs.hydra;

      # Hydra URL (used in notifications, links)
      hydraURL = "http://akos01:3000";

      # Email notifications
      smtpHost = "smtp.example.com";
      notificationSender = "hydra@example.com";

      # Build server settings
      minSpareServers = 2;
      maxSpareServers = 5;
      maxServers = 10;

      # Use substitutes (binary cache) for building dependencies
      useSubstitutes = true;

      # Tracker for hydra build inputs
      tracker = "some-tracker-url-or-id";

      # Additional flexible config adjustments
      extraConfig = ''
        logging: level = "info"
      '';
    };

    nix = {
      distributedBuilds = true;

      buildMachines = [
        {
          hostName = "localhost";
          system = "x86_64-linux";
          maxJobs = 8; # tune for your CPU
          speedFactor = 1;
          supportedFeatures = [
            "kvm"
            "nixos-test"
            "benchmark"
            "big-parallel"
          ];
          mandatoryFeatures = [];
          sshKey = null;
          protocol = null; # force local, no ssh
        }
      ];

      settings = {
        experimental-features = ["nix-command" "flakes"];
        build-users-group = "nixbld";
        # important: make Nix actually look at /etc/nix/machines
        builders = "@/etc/nix/machines";
        # allow cross/emulated builds
        extra-platforms = [
          "aarch64-linux"
          "aarch64-darwin"
          "x86_64-darwin"
        ];
      };
    };

    # Ensure QEMU is available for emulation
    boot.binfmt.emulatedSystems = lib.mkForce [
      "aarch64-linux"
    ];

    boot.loader.grub.enable = true;
    disko.devices = {
      disk = {
        main = {
          device = "/dev/vda";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              boot = {
                size = "1M";
                type = "EF02"; # for grub MBR
              };
              root = {
                size = "100%";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/";
                };
              };
            };
          };
        };
      };
    };
  };
}
