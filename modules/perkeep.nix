{
  config,
  pkgs,
  lib,
  pkgs-unstable,
  ...
}: {
  options = {
    MODULES.perkeep = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Perkeep";
      };
      port = lib.mkOption {
        type = lib.types.int;
        default = 3179;
        description = "The port Perkeep server listens on.";
      };
      options = lib.mkOption {
        type = lib.types.attrs;
        default = {
          auth = "tailscale:full-access-to-tailnet";
          baseURL = "https://${config.networking.fqdn}";
          listen = ":${toString config.MODULES.perkeep.port}";
          blobPath = "/var/lib/perkeep/blobs";
          sqlite = "/var/lib/perkeep/perkeep.sqlite3";

          #"auth"= "localhost";
          #"listen"= ":3179";
          "identity" = "3195C6090F5C8C2B";
          "identitySecretRing" = "/var/lib/perkeep/identity-secring.gpg";
          #"blobPath"= "/home/akos/var/perkeep/blobs";
          "packRelated" = true;
          #"sqlite"= "/home/akos/var/perkeep/index.sqlite";
        };
        description = "Options for Perkeep server";
      };
    };
  };

  config = lib.mkIf config.MODULES.perkeep.enable (
    let
      perkeep = pkgs-unstable.buildGoModule {
        name = "perkeep";
        vendorHash = "sha256-FLRfpyYVoZgV5LS2DjLOnc28Z+1v/YAxwWrOPoIzHHk=";

        src = pkgs.fetchFromGitHub {
          owner = "perkeep";
          repo = "perkeep";
          rev = "master";
          hash = "sha256-A52RfzqWTuU9UUdfGZwOdK6QlsxAheO+T0oVu8+uvaQ=";
        };
        postInstall = ''

          rm $out/bin/closure
          rm $out/bin/envvardoc
          rm $out/bin/scancab
          rm $out/bin/dev
          rm $out/bin/genclosuredeps
          rm $out/bin/scanningcabinet
          rm $out/bin/devcam
          rm $out/bin/hello
          rm $out/bin/publisher
          rm $out/bin/synology
          rm $out/bin/docker
          rm $out/bin/release

        '';

        doCheck = false;
      };

      configFile = builtins.toFile "config.json" (builtins.toJSON config.MODULES.perkeep.options);

      port = config.MODULES.perkeep.port;
    in {
      environment.systemPackages = [perkeep];

      systemd.services = {
        "perkeepd" = {
          description = "Perkeep server";
          after = ["network.target"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            ExecStart = "${perkeep}/bin/perkeepd -configfile ${configFile}";
            User = "root";
            Restart = "always";
            StateDirectory = "perkeep";
            WorkingDirectory = "/var/lib/perkeep";
          };
        };
      };
    }
  );
}
