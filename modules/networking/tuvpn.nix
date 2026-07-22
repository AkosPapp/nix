{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.MODULES.networking.tuvpn;

  tuvpn-connect = pkgs.writeShellScriptBin "tuvpn-connect" ''
    set -euo pipefail

    VPN_HOST="vpn.tuwien.ac.at"

    USER=$(cat ${config.sops.secrets."tu/vpn/user".path})
    PASS=$(cat ${config.sops.secrets."tu/vpn/pass".path})
    TOTP_SECRET=$(cat ${config.sops.secrets."tu/vpn/totp".path})

    PROFILE=$(printf "1_TU_getunnelt\n2_Alles_getunnelt\n" | \
      ${pkgs.wofi}/bin/wofi --dmenu --prompt="Select VPN profile" --lines=2)

    if [[ -z "$PROFILE" ]]; then
      echo "No profile selected, aborting." >&2
      exit 1
    fi

    OTP=$(${pkgs.oath-toolkit}/bin/oathtool --totp -b "$TOTP_SECRET")

    echo "Connecting to $VPN_HOST with profile '$PROFILE'..."

    printf '%s\n%s\n' "$PASS" "$OTP" | \
      sudo ${pkgs.openconnect}/bin/openconnect \
        --protocol=anyconnect \
        --no-dtls \
        --no-external-auth \
        --authgroup="$PROFILE" \
        --user="$USER" \
        --passwd-on-stdin \
        "$VPN_HOST"
  '';
in {
  options = {
    MODULES.networking.tuvpn.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the TU Wien VPN helper (tuvpn-connect)";
    };
  };

  config = lib.mkIf cfg.enable {
    MODULES.security.sops.enable = true;
    sops.secrets."tu/vpn/user" = {
      owner = "akos";
      group = "users";
    };
    sops.secrets."tu/vpn/pass" = {
      owner = "akos";
      group = "users";
    };
    sops.secrets."tu/vpn/totp" = {
      owner = "akos";
      group = "users";
    };

    environment.systemPackages = [
      tuvpn-connect
    ];

    security.sudo.extraRules = [
      {
        users = ["akos"];
        commands = [
          {
            command = "${pkgs.openconnect}/bin/openconnect";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
  };
}
