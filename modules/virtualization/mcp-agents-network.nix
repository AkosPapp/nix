{
  config,
  lib,
  pkgs,
  ...
}: {
  options.MODULES.virtualisation.mcpAgentsNetwork.enable = lib.mkEnableOption ''
    the "mcp-agents" Docker bridge network. mcp-context-forge.nix and n8n.nix each turn this on
    themselves when enabled, so the two containers can reach each other by container name
    (Docker's embedded DNS resolves them on a user-defined bridge network, unlike the default
    bridge) - the shared network the top-level task description asks for. Neither talks to
    LiteLLM over it: LiteLLM runs with --network=host (see litellm.nix, which several other
    hosts' vLLM backends depend on unchanged), so n8n reaches it via host.docker.internal
    instead - see n8n.nix
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
