{config, pkgs, lib, ... }:
{
    options = {
        MODULES.wm.dwmblocks.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable custom dwmblocks";
        };
    };
    config = lib.mkIf config.MODULES.wm.dwmblocks.enable {
        environment.systemPackages = with pkgs; [
            dwmblocks
        ];
        nixpkgs.overlays = [
            (final: prev: {
             dwmblocks = prev.dwmblocks.overrideAttrs (old: { src = ./dwmblocks ;});
             })
        ];
    };
}
