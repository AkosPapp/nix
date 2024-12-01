{
  config,
  pkgs,
  options,
  lib,
  ...
}: {
  options = {
    MODULES.virtualisation.vmware.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable VMware virtualisation";
    };
  };

  config = lib.mkIf config.MODULES.virtualisation.vmware.enable {
    virtualisation.vmware.host.enable = true;
  };
}
