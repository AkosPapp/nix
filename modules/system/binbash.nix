{ config, lib, pkgs, ... }:

with lib;

{

    options = {
        environment.binbash = mkOption {
            default = false;
            type = types.bool;
            description = "Include a /bin/bash in the system.";
        };
    };

    config = {

        system.activationScripts.binbash = if config.environment.binbash
            then ''
            mkdir -m 0755 -p /bin
            ln -s /bin/sh /bin/bash || true
            ''
            else ''
                rm -f /bin/bash
                rmdir -p /bin || true
            '';

    };

}
