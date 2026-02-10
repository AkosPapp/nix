{
  pkgs,
  lib,
  modulesPath,
  pkgs-unstable,
  config,
  ...
}: {
  config = {
    MODULES.nix.builders.airlab = true;
    MODULES.security.vaultwarden.enable = true;
    MODULES.networking.tailscale.hostIP = "100.83.255.5";
    MODULES.networking.searx.enable = true;
    PROFILES.qemu-vm.enable = true;

    services.nix_autobuild = {
      enable = true;
      settings = {
        repos = [
          {
            url = "github.com/PPAPSONKA/nix";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 5;
          }
          {
            url = "github.com/PPAPSONKA/nixvim";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 5;
          }
          {
            url = "github.com/AkosPapp/nix_autobuild";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 5;
          }
          {
            url = "github.com/AkosPapp/rs_reverse_proxy";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 5;
          }
          {
            url = "git.robo4you.at/akos.papp/DA";
            poll_interval_sec = 30;
            branches = ["main"];
            build_depth = 5;
          }
          # {
          #   url = "git.robo4you.at/flyby/blender-sdg";
          #   poll_interval_sec = 30;
          #   branches = ["main"];
          #   build_depth = 5;
          # }
        ];
        dir = "/tmp/nix_autobuild";
        supported_architectures = ["x86_64-linux" "aarch64-linux"];
        host = "127.0.0.1";
        port = 8085;
      };
    };
    MODULES.networking.reverse-proxy.enable = true;
    MODULES.networking.reverse-proxy.options.patterns = {
      "^https://${config.networking.fqdn}/nix" = "http://127.0.0.1:8085";
    };

    # Traefik reverse proxy configuration
    MODULES.networking.traefik.enable = true;

    networking = {
      useDHCP = true;
    };

    environment.systemPackages = with pkgs; [
      vim
      wget
      curl
      git
      htop
      tmux
      dnsutils
    ];

    services.tailscale = {
      extraSetFlags = lib.mkForce ["--accept-dns=false" "--accept-routes=false" "--advertise-routes=10.50.0.0/23,10.44.0.0/24,172.18.0.252/32"];
      useRoutingFeatures = "both";
    };

    MODULES.security.sops.enable = true;
    sops.secrets."nix-serve/akos01.tail546fb.ts.net/private_key" = {
      mode = "0400";
      #owner = "nix-serve";
      #group = "nix-serve";
    };
    MODULES.networking.tailscale.serve."nix-serve" = {
      target = "5000";
      httpsPort = 8443;
      type = "funnel";
    };
    services.nix-serve = {
      enable = true;
      secretKeyFile = config.sops.secrets."nix-serve/akos01.tail546fb.ts.net/private_key".path;
      #package = pkgs.nix-serve-ng;
    };
    nix.settings = {
      download-buffer-size = 524288000; # 500 MiB
    };

    networking.hostId = "68bf4e0e";
    boot.loader.grub.enable = true;
    boot.supportedFilesystems = ["zfs"];
    boot.zfs.forceImportRoot = true;
    boot.zfs.devNodes = "/dev";
    boot.loader.grub.zfsSupport = true;

    fileSystems."/" = {
      device = "zroot/root";
      fsType = "zfs";
      neededForBoot = true;
    };
    fileSystems."/nix" = {
      device = "zroot/nix";
      fsType = "zfs";
      neededForBoot = true;
    };

    swapDevices = [
      {device = "/dev/disk/by-label/NIXOS_SWAP_VDA";}
      {device = "/dev/disk/by-label/NIXOS_SWAP_VDB";}
    ];

    disko.devices.disk = {
      VDA = {
        device = "/dev/vda";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02";
            };
            boot-ext4 = {
              size = "1G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/boot";
                mountOptions = ["defaults"];
              };
            };
            zfs = {
              end = "-16G"; # leave 16G for swap at the end of the disk
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
                resumeDevice = false; # resume from hibernation from this device
                extraArgs = ["-L" "NIXOS_SWAP_VDA"]; # unique label for the swap partition on vda
              };
            };
          };
        };
      };
      VDB = {
        device = "/dev/vdb";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              end = "-16G"; # leave 16G for swap at the end of the disk
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
                resumeDevice = false; # resume from hibernation from this device
                extraArgs = ["-L" "NIXOS_SWAP_VDB"]; # unique label for the swap partition on vdb
              };
            };
          };
        };
      };
    };

    disko.devices.zpool = {
      zroot = {
        type = "zpool";
        mountpoint = null;
        rootFsOptions = {
          compression = "off";
          "com.sun:auto-snapshot" = "false";
        };

        datasets = {
          root = {
            type = "zfs_fs";
            mountpoint = "/";
            options.canmount = "noauto";
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.canmount = "noauto";
          };
        };
      };
    };
  };
}
