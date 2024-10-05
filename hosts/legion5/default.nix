{
  config,
  pkgs,
  lib,
  nixos-hardware,
  sops-nix,
  ...
}: {
  imports = [./hardware-configuration.nix ./disko.nix];
  # This will add secrets.yml to the nix store
  # You can avoid this by adding a string to the full path instead, i.e.
  # sops.defaultSopsFile = "/root/.sops/secrets/example.yaml";
  sops.defaultSopsFile = ./secrets/example.yaml;
  # This will automatically import SSH keys as age keys
  # sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  # This is using an age key that is expected to already be in the filesystem
  sops.age.keyFile = "/home/akos/.config/sops/age/keys.txt";
  # This will generate a new key if the key specified above does not exist
  sops.age.generateKey = false;
  # This is the actual specification of the secrets.
  # sops.secrets.example-key = {};
  # sops.secrets."myservice/my_subdir/my_secret" = {};

  #  # Bootloader.
  #  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  networking = {
    networkmanager.enable = true;
    hostId = "68bf4e0e";
    hostName = "legion5";
    extraHosts = ''
      127.0.0.1 localhost
    '';
  };

  MODULES.system.printing.enable = true;

  users.users.root.hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  system.stateVersion = "24.05";

  USERS.akos.enable = true;

  services.xserver.displayManager.gdm.enable = true;

  environment.systemPackages = with pkgs; [
    lenovo-legion
    docker
    nvidia-docker
    cudatoolkit
  ];

  # Enable OpenGL
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
    extraPackages = with pkgs; [
      vaapiVdpau
      libvdpau-va-gl
      libvdpau-va-gl
    ];
  };

  services.logind = {
    powerKey = "suspend";
    lidSwitch = "suspend";
  };

  services.znapzend = {
    enable = true;
    pure = true;
    autoCreation = true;
    logLevel = "debug";
    logTo = "/var/log/znapzend.log";
    features = {
      compressed = true;
      lowmemRecurse = true;
      skipIntermediates = true;
    };
    zetup."zroot/persist" = {
      recursive = true;
      plan = "1h=>1min,1d=>1h,1w=>1d";
      enable = true;
      destinations = {
        "laptop-srv" = {
          host = "root@laptop-srv";
          dataset = "zroot/persist";
          plan = "1h=>1min,1d=>1h,1w=>1d";
        };
      };
    };
  };

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "weekly";
    };
    trim = {
      enable = true;
      interval = "daily";
    };
  };

  #services.autorandr.profiles = {
  #  enable = true;
  #  default = {
  #    fingerprint = {
  #      eDP-1-0 = "00ffffffffffff000e6f001600000000001e0104b522167803ee95a3544c99260f5054000000010101010101010101010101010101016e6e00a0a04084603020360059d710000018000000fd0c3ca51f1f4e010a202020202020000000fe0043534f542054330a2020202020000000fe004d4e473030374441312d310a20020202031d00e3058000e60605016a6a246d1a000002033ca500046a246a240000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ff7013790000030114ac2f0185ff099f002f001f003f0683000200050000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003790";
  #    };
  #    config = {
  #      eDP-1-0 = {
  #        enable = true;
  #        crtc = 0;
  #        primary = true;
  #        position = "0x0";
  #        mode = "2560x1600";
  #        gamma = "1.0:1.0:1.0";
  #        rate = "165.00";
  #        dpi = 189;
  #      };
  #    };
  #  };
  #};

  services.power-profiles-daemon.enable = true;
}
