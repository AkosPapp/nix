{
  pkgs,
  lib,
  modulesPath,
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
    nix.settings.experimental-features = ["nix-command" "flakes"];

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
    ];

    MODULES.networking.tailscale.enable = lib.mkForce true;
    services.tailscale = {
      enable = true;
      openFirewall = true;
      extraSetFlags = lib.mkForce ["--accept-dns=false" "--advertise-exit-node" "--accept-routes=false" "--advertise-routes=10.50.0.0/23,10.44.0.0/24,172.18.0.0/16"];
      useRoutingFeatures = "both";
    };
    networking.firewall.checkReversePath = "loose";

    services.qemuGuest.enable = true;

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
