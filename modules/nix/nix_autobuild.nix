{
  config,
  pkgs,
  options,
  lib,
  ...
}: {
  options = {
    MODULES.nix.autobuild = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable nix autobuild service.";
      };

      options = {
        repos = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule {
            options = {
              url = lib.mkOption {
                type = lib.types.str;
                description = "The URL of the git repository.";
              };
              name = lib.mkOption {
                type = lib.types.str;
                description = "The name of the repository.";
              };
              poll_interval_sec = lib.mkOption {
                type = lib.types.int;
                default = 60;
                description = "Polling interval in seconds.";
              };
            };
          });
          default = [];
          description = "List of repositories to monitor and build.";
        };

        dir = lib.mkOption {
          type = lib.types.str;
          default = "data";
          description = "Directory to store build data.";
        };

        supported_architectures = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["x86_64-linux"];
          description = "List of supported architectures for building.";
        };
      };
    };
  };

  config = lib.mkIf config.MODULES.nix.autobuild.enable (
    let
      configFile = builtins.toFile "config.json" (builtins.toJSON config.MODULES.nix.autobuild.options);

      nix_autobuild = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
        pname = "nix_autobuild";
        version = "0.1.0";

        src = pkgs.fetchFromGitHub {
          owner = "AkosPapp";
          repo = "nix_autobuild";
          rev = "main";
          hash = "sha256-g2VpU4Fw8lJWGu+m+nFzyCjOUGNEqAqUAiRdDUJWpEg=";
        };

        cargoHash = "sha256-VEhIBfWhLjb7K/ni6FyJX1fsw0hBYiyTXUKVWT3BTcM=";

        meta = {
          description = "A simple build tool for Nix projects.";
          homepage = "https://github.com/AkosPapp/nix_autobuild";
          license = lib.licenses.unlicense;
          maintainers = [];
        };
      });
    in {
      systemd.services = {
        "nix_autobuild" = {
          description = "A simple build tool for Nix projects.";
          after = ["network.target"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            ExecStart = "${nix_autobuild}/bin/nix_autobuild ${configFile}";
            User = "root";
            Restart = "always";
          };
        };
      };
    }
  );
}
