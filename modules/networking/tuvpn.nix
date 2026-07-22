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

    PROFILE=$(printf "1_TU_getunnelt\n2_Alles_getunnelt\n3_TU_ohne_fixe_Adresse\nDisconnect\n" | \
      ${pkgs.wofi}/bin/wofi --dmenu --prompt="Select VPN profile" --lines=4)

    if [[ -z "$PROFILE" ]]; then
      echo "No profile selected, aborting." >&2
      exit 1
    fi

    sudo ${pkgs.psmisc}/bin/killall openconnect || true

    if [[ "$PROFILE" == "Disconnect" ]]; then
      echo "Disconnected from $VPN_HOST."
      exit 0
    fi

    USER=$(cat ${config.sops.secrets."tu/vpn/user".path})
    PASS=$(cat ${config.sops.secrets."tu/vpn/pass".path})
    TOTP_SECRET=$(cat ${config.sops.secrets."tu/vpn/totp".path})

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

  tuvpn-connect-desktop = pkgs.makeDesktopItem {
    name = "tuvpn-connect";
    desktopName = "TU VPN";
    comment = "Connect to or disconnect from the TU Wien VPN";
    icon = "network-vpn";
    exec = "${tuvpn-connect}/bin/tuvpn-connect";
    terminal = false;
    categories = ["Network"];
  };
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
      tuvpn-connect-desktop
    ];

    security.sudo.extraRules = [
      {
        users = ["akos"];
        commands = [
          {
            command = "${pkgs.openconnect}/bin/openconnect";
            options = ["NOPASSWD"];
          }
          {
            command = "${pkgs.psmisc}/bin/killall openconnect";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
  };
}
