{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.hermes-ics;
  hermes = config.services.hermes-agent;
  hermesModule = config.MODULES.services.hermes-agent;
  traefik = config.MODULES.networking.traefik;

  # One-file HTTP server: answers exactly `<publicPath>/<token>/<ics file name>` with the current
  # bytes of the ICS file and nothing else, so the token in the path is the only thing standing
  # between the internet and the calendar (which is the whole design: Google fetches the feed
  # unauthenticated, so an unguessable URL is the auth). It re-reads both files per request, so
  # regenerating the feed needs no restart and a rotated token only needs one (the secret's
  # restartUnits below).
  server = pkgs.writeTextFile {
    name = "hermes-ics-server";
    destination = "/bin/hermes-ics-server";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      import http.server
      import os
      import pathlib

      public = os.environ["ICS_PUBLIC_PATH"]
      ics = pathlib.Path(os.environ["ICS_FILE"])
      token = pathlib.Path(os.environ["ICS_TOKEN_FILE"]).read_text().strip()
      if not token:
          raise SystemExit("empty ICS token")
      path = f"{public}/{token}/{ics.name}"
      port = int(os.environ["ICS_PORT"])


      # NB: answer from do_GET/do_HEAD, never by overriding `handle()`: the base handle() is what
      # parses the request line and dispatches, so an override sees no self.path and the client
      # gets a closed socket with no response (Traefik renders that as 502).
      class Handler(http.server.BaseHTTPRequestHandler):
          def respond(self, body=True):
              try:
                  data = ics.read_bytes()
              except OSError:
                  self.send_error(503, "feed not ready")
                  return
              if self.path != path:
                  self.send_error(404)
                  return
              self.send_response(200)
              self.send_header("Content-Type", "text/calendar; charset=utf-8")
              self.send_header("Content-Length", str(len(data)))
              self.send_header("Cache-Control", "no-store")
              self.end_headers()
              if body:
                  self.wfile.write(data)

          def do_GET(self):
              self.respond()

          def do_HEAD(self):
              self.respond(body=False)

          def log_message(self, *args):
              pass


      http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
    '';
  };
in {
  options.MODULES.services.hermes-ics = {
    enable = mkEnableOption ''
      a public (token-gated) ICS feed for Hermes' calendar file: a loopback file server on this
      host plus one route on Traefik's public entry point, so the feed is reachable at
      `<funnel origin>/ics/<token>/hermes.ics` from anywhere - Google Calendar and friends
      included, which is exactly what the Tailscale `serve` command must NOT be used for (a serve
      entry on 443 steals the port from Traefik and takes down every <service>.<host> on the
      tailnet; see the RUNBOOK)
    '';

    icsFile = mkOption {
      type = types.str;
      default = "${hermes.stateDir}/ics-serve/hermes.ics";
      defaultText = lib.literalExpression ''config.services.hermes-agent.stateDir + "/ics-serve/hermes.ics"'';
      description = ''
        The file to serve. Hermes (or any cron job on the hermes uid) rewrites it in place; the
        server re-reads it on every request. It must stay readable by (and ideally owned by) the
        hermes user, since the server runs as hermes.
      '';
    };

    tokenSecret = mkOption {
      type = types.str;
      default = "hermes/ics_token";
      description = ''
        sops secret holding the long random token that makes the feed URL unguessable (hex, 32+
        bytes). Anyone who knows the URL can read the calendar, so treat the URL as a credential
        when pasting it around; rotating the secret restarts the server (and changes the URL).
      '';
    };

    publicPath = mkOption {
      type = types.str;
      default = "/ics";
      description = "Path prefix this feed claims on the shared Funnel origin.";
    };

    baseUrl = mkOption {
      type = types.str;
      readOnly = true;
      default = traefik.public.urlOf cfg.publicPath;
      defaultText = lib.literalExpression ''MODULES.networking.traefik.public.urlOf "<public path>"'';
      description = ''
        Everything before the token: `<funnel origin>/ics`. The full feed URL is
        `<baseUrl>/<token>/hermes.ics`, with the token from `tokenSecret` (decrypt it with
        `sops -d sops/secrets.yaml` on a machine holding the age key - nix cannot know it at
        build time, which is the point).
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = hermes.enable;
        message = "MODULES.services.hermes-ics needs MODULES.services.hermes-agent (it serves Hermes' file as the hermes user).";
      }
    ];

    sops.secrets.${cfg.tokenSecret} = {
      restartUnits = ["hermes-ics.service"];
    };

    systemd.services.hermes-ics = {
      description = "Hermes ICS feed (loopback, token-gated)";
      after = ["network.target"];
      wantedBy = ["multi-user.target"];
      environment = {
        ICS_PUBLIC_PATH = cfg.publicPath;
        ICS_FILE = cfg.icsFile;
        ICS_PORT = toString config.PORTS.hermesIcs;
        ICS_TOKEN_FILE = "/run/credentials/hermes-ics.service/ics_token";
      };
      # The Hermes sandbox (exported by hermes-agent.nix for exactly this kind of reuse, see
      # paseo-hermes.nix): same uid, same filesystem view - the ICS file lives inside the state
      # dir it already bind-mounts.
      serviceConfig =
        hermesModule.paseoHermesSandbox
        // {
          User = hermes.user;
          LoadCredential = ["ics_token:${config.sops.secrets.${cfg.tokenSecret}.path}"];
          ExecStart = "${server}/bin/hermes-ics-server";
          Restart = "always";
          RestartSec = "5s";
        };
    };

    MODULES.networking.traefik.public = {
      enable = true;
      # No stripPrefix: the server matches the full path including the token, so a request to
      # /ics (or any wrong token) never even reaches a handler that could answer with the feed.
      routes.hermes-ics = {
        pathPrefix = cfg.publicPath;
        target = "127.0.0.1:${toString config.PORTS.hermesIcs}";
      };
    };
  };
}
