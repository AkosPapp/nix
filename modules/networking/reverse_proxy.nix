{
  config,
  pkgs,
  options,
  lib,
  ...
}: {
  options = {
    MODULES.networking.reverse-proxy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable reverse proxy services.";
      };

      options = {
        address = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          description = "The address to bind to.";
        };

        port = lib.mkOption {
          type = lib.types.int;
          default = 80;
          description = "The port to listen on.";
        };

        patterns = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {
          };
          description = "Mapping of URL patterns to backend URLs.";
        };
      };
    };
  };

  config = lib.mkIf config.MODULES.networking.reverse-proxy.enable (
    let
      port = config.MODULES.networking.reverse-proxy.options.port;

      configFile = builtins.toFile "config.json" (builtins.toJSON config.MODULES.networking.reverse-proxy.options);

      rs_reverse_proxy = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
        pname = "rs_reverse_proxy";
        version = "0.1.0";

        src = pkgs.fetchFromGitHub {
          owner = "AkosPapp";
          repo = "rs_reverse_proxy";
          rev = "main";
          hash = "sha256-b/+7d2QS/81qiGSDKEcWbBRPmTasApVkjK2A6fiSri8=";
        };

        cargoHash = "sha256-I1dQ8ef8PiPbF/37OxJknsWSXwqRVvzdFvThpkr/PAo=";

        meta = {
          description = "A simple reverse proxy written in Rust.";
          homepage = "https://github.com/AkosPapp/rs_reverse_proxy";
          license = lib.licenses.unlicense;
          maintainers = [];
        };
      });
    in {
      systemd.services = {
        "tailscale-serve" = {
          description = "Tailscale serve on port ${toString port}";
          after = ["tailscaled.service" "network.target" "reverse-proxy.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            ExecStart = "${pkgs.tailscale}/bin/tailscale serve ${toString port}";
            User = "root";
            Restart = "always";
          };
        };
        "reverse-proxy" = {
          description = "Rust Reverse Proxy Service";
          after = ["network.target"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            ExecStart = "${rs_reverse_proxy}/bin/rs_reverse_proxy ${configFile}";
            User = "root";
            Restart = "always";
          };
        };
      };
    }
  );
}
