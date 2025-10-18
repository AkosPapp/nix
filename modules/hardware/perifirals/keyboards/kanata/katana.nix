{
  lib,
  pkgs,
  config,
  ...
}: {
  options = {
    MODULES.hardware.perifirals.keyboards.kanata.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable home row mods with kanata";
    };
  };

  config = lib.mkIf config.MODULES.hardware.perifirals.keyboards.kanata.enable {
    systemd.services.kanata = {
      enable = true;
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        ExecStart = "${pkgs.kanata}/bin/kanata -c ${./config.kbd}";
        User = "root";
      };
    };
  };
}
