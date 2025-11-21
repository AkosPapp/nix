{
  config,
  lib,
  pkgs,
  ...
}: {
  options = {
    PROFILES.zroot.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable zroot profile";
    };
  };

  config = lib.mkIf config.PROFILES.zroot.enable {
    networking.hostId = "68bf4e0e";
    boot = {
      supportedFilesystems = ["zfs"];
      zfs = {
        extraPools = ["zroot"];
        forceImportRoot = true;
        allowHibernation = false;
      };
    };
    fileSystems."/" = {
      device = "zroot/root";
      fsType = "zfs";
    };

    fileSystems."/nix" = {
      device = "zroot/nix";
      fsType = "zfs";
    };

    disko.devices = {
      zpool = {
        zroot = {
          type = "zpool";
          mountpoint = null;
          postCreateHook = "zfs snapshot zroot@blank && zfs snapshot zroot/root@blank";
          rootFsOptions = {
            compression = "off";
            "com.sun:auto-snapshot" = "false";
          };

          datasets = {
            root = {
              type = "zfs_fs";
              mountpoint = "/";
            };
            nix = {
              type = "zfs_fs";
              mountpoint = "/nix";
            };
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

    environment.systemPackages = with pkgs; [
      sanoid
      lz4
      mbuffer
      socat
    ];
  };
}
