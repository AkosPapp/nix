{
  config,
  lib,
  pkgs,
  ...
}: {
  options.MODULES.virtualisation.mcpAgentsNetwork.enable = lib.mkEnableOption ''
    the "mcp-agents" Docker bridge network. n8n.nix turns this on when enabled, though n8n's own
    container currently runs with --network=host instead (see n8n.nix), reaching every other
    local service over 127.0.0.1 directly rather than by container name on this bridge - kept
    around for any future container-backed service that does need Docker's embedded DNS to
    resolve a peer by name.
  '';

  config = lib.mkIf config.MODULES.virtualisation.mcpAgentsNetwork.enable {
    virtualisation.docker.enable = true;

    # oci-containers/`docker run` only accepts one --network at container creation, so the
    # network itself has to be created out-of-band rather than declared on either container.
    # Idempotent by hand rather than via `docker network create --ignore-existing` - that flag
    # doesn't exist - so a restart of this unit (or a second container's ExecStartPre racing it)
    # doesn't fail on "network already exists".
    systemd.services.mcp-agents-network = {
      description = ''Create the "mcp-agents" Docker bridge network'';
      after = ["docker.service"];
      requires = ["docker.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.docker}/bin/docker network inspect mcp-agents >/dev/null 2>&1 || \
          ${pkgs.docker}/bin/docker network create mcp-agents
      '';
    };
  };
}
