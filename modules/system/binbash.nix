{
  config,
  lib,
  pkgs,
  ...
}:
with lib; {
  options = {
    MODULES.system.binbash.enable = mkOption {
      default = false;
      type = types.bool;
      description = "Include a /bin/bash in the system.";
    };
  };

  config = {
    system.activationScripts.binbash =
      if config.MODULES.system.binbash.enable
      then ''
        mkdir -m 0755 -p /bin
        [ -f /bin/bash ] || ln -s /bin/sh /bin/bash
      ''
      else ''
        [ -f /bin/bash ] && rm -f /bin/bash
      '';
  };
}
