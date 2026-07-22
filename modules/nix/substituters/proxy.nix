{
  config,
  lib,
  ...
}: {
  options = {
    MODULES.nix.substituters.proxy.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable nix_ssh_serve_proxy proxy";
    };
  };

  config = lib.mkIf config.MODULES.nix.substituters.proxy.enable {
    services.nix_serve_proxy = {
      proxy = {
        enable = true;
        hosts =
          lib.optional (config.networking.hostName != "akos01") "http://akos01.airlab:5001"
          ++ lib.optional (config.networking.hostName != "hp") "http://hp.tail546fb.ts.net:5001"
          ++ ["http://cache.nixos.org"];
        http_port = 5000;
        http_bind_address = "127.0.0.1";
        availability_cache_ttl_secs = 300;
        narinfo_cache_ttl_secs = 300;
        download_size = 10000;
        max_downloads_per_host = 16;
        max_downloads_per_nar = 16;
        want_mass_query = true;
        priority = 0;
      };
    };

    nix = {
      settings = {
        substituters = [
          "http://localhost:5000"
        ];
        trusted-substituters = [
          "http://localhost:5000"
        ];
        trusted-public-keys = [
          "akos01.airlab:xT0wS6R0UZTtPqVNVb9boPkSfxAf47uS8zEEnzFgfkk="
        ];
      };
    };
  };
}
