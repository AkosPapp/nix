{ pkgs, lib, config, ... }: {
  options = {
    MODULES.system.zfs.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable zfs support";
    };
  };

  config = lib.mkIf config.MODULES.system.zfs.enable {
    environment.systemPackages = with pkgs; [ sanoid lz4 lzo mbuffer ];
    boot.supportedFilesystems = [ "zfs" ];
  };
}
