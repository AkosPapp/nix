{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption mkIf mkMerge mkEnableOption types;

  cfg = config.MODULES.networking.sshd;
in {
  options = {
    MODULES.networking.sshd = {
      enable = mkEnableOption "the OpenSSH daemon.";

      x11Forwarding = mkOption {
        type = types.bool;
        default = true;
        description = ''
          X11 forwarding (sshd's X11Forwarding plus the client-side forwardX11 default).
          A convenience for the laptop; off on servers - a compromised remote X client gets
          a session on the host (2026-10-24 audit #8).
        '';
      };

      agentAuth = mkOption {
        type = types.bool;
        default = true;
        description = ''
          security.pam.sshAgentAuth: an ssh-agent can hold the keys that authenticate *into*
          this host. That makes any machine with a forwarded copy of those keys equivalent to
          the key holder here, so it is off wherever an interactive human does not need it
          (2026-10-24 audit #8).
        '';
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      programs.ssh.forwardX11 = cfg.x11Forwarding;
      services.openssh = {
        enable = true;
        settings =
          {
            # Forwarded X11 sockets on loopback only, even where forwarding is on (audit #8).
            X11UseLocalhost = true;
            PermitRootLogin = "prohibit-password";
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
          }
          // lib.optionalAttrs cfg.x11Forwarding {
            X11Forwarding = true;
          };
      };
    })
    (mkIf (cfg.enable && cfg.agentAuth) {
      security.pam.sshAgentAuth.enable = true;
    })
  ];
}
