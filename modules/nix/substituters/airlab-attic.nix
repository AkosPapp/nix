{
  config,
  pkgs,
  lib,
  ...
}: let
  atticConfig = pkgs.writeText "attic-config.toml" ''
    default-server = "airlab"

    [servers.airlab]
    endpoint = "https://attic.airlab.at/"
    token-file = "${config.sops.secrets."attic/akos/token".path}"
  '';
in {
  options = {
    MODULES.nix.substituters.airlab-attic.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable attic.airlab.at/akos substituter";
    };

    MODULES.nix.substituters.airlab-attic.push.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Watch the local Nix store and automatically push new paths to attic.airlab.at/akos";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.MODULES.nix.substituters.airlab-attic.enable {
      environment.systemPackages = [pkgs.attic-client];

      sops.secrets."attic/akos/token" = {
        mode = "0400";
      };

      # attic.airlab.at/akos is a private cache; the nix daemon authenticates its
      # own fetches (pulls) the same way `attic use` would set it up - via a
      # netrc file referenced from nix.conf.
      sops.templates."attic-netrc".content = ''
        machine attic.airlab.at
        password ${config.sops.placeholder."attic/akos/token"}
      '';

      nix = {
        settings = {
          substituters = [
            "https://attic.airlab.at/akos"
          ];
          trusted-substituters = [
            "https://attic.airlab.at/akos"
          ];
          trusted-public-keys = [
            "akos:Ns/5p5/VFeYPqQBWuolbgUspQ+05OChiBMhrLXM9Sxw="
          ];
          netrc-file = config.sops.templates."attic-netrc".path;
        };
      };

      # Make the `attic` CLI usable as root (e.g. `sudo attic push akos ...`)
      # without a manual `attic login`.
      systemd.tmpfiles.rules = [
        "d /root/.config 0700 root root -"
        "d /root/.config/attic 0700 root root -"
        "L+ /root/.config/attic/config.toml - - - - ${atticConfig}"
      ];
    })

    (lib.mkIf config.MODULES.nix.substituters.airlab-attic.push.enable {
      systemd.services.attic-watch-store = {
        description = "Watch the Nix store and push new paths to attic.airlab.at/akos";
        wantedBy = ["multi-user.target"];
        after = ["network-online.target"];
        wants = ["network-online.target"];

        environment.XDG_CONFIG_HOME = "/var/lib/attic-watch-store/.config";

        serviceConfig = {
          StateDirectory = "attic-watch-store";
          ExecStartPre = "${pkgs.coreutils}/bin/install -D -m 0400 ${atticConfig} /var/lib/attic-watch-store/.config/attic/config.toml";
          ExecStart = "${pkgs.attic-client}/bin/attic watch-store akos";
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };
    })
  ];
}
