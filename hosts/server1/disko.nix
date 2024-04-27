{ disko }: {
  imports = [ disko.nixosModules.disko ];

  disko.devices = {
    disk = {
      root = {
        device = "/dev/disk/by-id/usb-Verbatim_STORE_N_GO_23101424050993-0:0";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              type = "EF00";
              size = "500M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
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
}
