{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
  options = {
    MODULES.networking.tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Tailscale VPN";
    };
  };

  config = lib.mkIf config.MODULES.networking.tailscale.enable {
    services.tailscale = {
      enable = true;
      openFirewall = true;
      extraSetFlags = ["--accept-dns=false"];
      package = pkgs-unstable.tailscale;
    };
    networking.search = ["tail546fb.ts.net"];
    networking.firewall.checkReversePath = "loose";
    networking.nameservers = [
      #"172.16.0.1"
      #"100.100.100.100"
      #"9.9.9.9"
      #"8.8.8.8"
      #"1.1.1.1"
      "127.0.0.1"
    ];
    services.dnsmasq = {
      enable = true;
      settings = {
        # Set up DNS forwarding for specific domains
        server = [
          "/local/"
          "/homenet/"
          "/airlab/"
          "/tail546fb.ts.net/100.100.100.100"
          "9.9.9.9"
          "1.1.1.1"
          "8.8.8.8"
        ];

        # CNAME mapping for tailnet
        cname = "tailnet,tail546fb.ts.net";

        # Forward all other DNS queries to upstream servers

        # Ensure that dnsmasq uses DHCP-assigned DNS servers (if applicable)
        # This line might not be strictly necessary if it's enabled by default
        # server = [ "/<domain>/dhcp" ];  # Replace <domain> with the specific domain if needed

        # Configuration files for DNS resolution
        resolv-file = "/etc/dnsmasq-resolv.conf";
        conf-file = "/etc/dnsmasq-conf.conf";
      };
    };
  };
}
