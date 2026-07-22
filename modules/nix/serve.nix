{
  config,
  lib,
  ...
}: {
  options = {
    MODULES.nix.serve.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable nix_ssh_serve_proxy server";
    };
  };

  config = lib.mkIf config.MODULES.nix.serve.enable {
    sops.secrets."nix-serve/akos01.airlab/private_key" = {
      mode = "0400";
      #owner = "nix-serve";
      #group = "nix-serve";
    };
    services.nix_ssh_serve_proxy = {
      server = {
        enable = true;
        http_port = 5001;
        http_bind_address = "0.0.0.0";
        want_mass_query = true;
        priority = 1;
        signing_key_file = "/var/cache-priv-key.pem";
      };
    };
  };
}
