{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.n8n-sandbox;

  network = "n8n-sandbox";
  tlsVolume = "n8n-sandbox-tls";

  # Read by n8n.nix (config.sops.secrets."n8n-sandbox/api_key".path) to authenticate to
  # sandbox-api as a client - same cross-module-by-known-name pattern as mcp-context-forge.nix's
  # token files, except this one really is a sops secret (both sides need the same value, unlike
  # a token minted after the fact) rather than a path a oneshot service writes.
  apiKeySecret = "n8n-sandbox/api_key";
  registrationTokenSecret = "n8n-sandbox/registration_token";
  runnerKeySecret = "n8n-sandbox/runner_key";
in {
  options.MODULES.services.n8n-sandbox = {
    enable = mkEnableOption ''
      the sandbox stack n8n's AI Assistant/Agent needs to execute code on your behalf (distinct
      from MODULES.services.n8n.sandbox, which restricts what a workflow's own Code node may do -
      this is n8n's own upstream code-writing assistant asking an LLM to run something for you).
      Three containers on a dedicated bridge network: sandbox-certs (a oneshot job that bootstraps
      mTLS certs into a shared volume, then exits), sandbox-api (the control plane n8n talks to),
      and sandbox-runner-1 (a *privileged* Docker-in-Docker container that actually creates and
      runs the per-execution sandboxes) - see
      https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-n8n-assistant. n8n.nix wires
      N8N_INSTANCE_AI_SANDBOX_*/N8N_SANDBOX_SERVICE_* into the n8n container automatically once
      this is enabled; there's nothing to paste into n8n's own "Add a code sandbox" dialog.

      sandbox-runner-1 running privileged is load-bearing, not incidental - it's how upstream's
      own reference docker-compose stack runs it too, since it needs to create and manage Docker
      containers of its own for each sandboxed execution. Give this its own host, or at least
      weigh that against whatever else is on this one, before turning it on.
    '';

    serviceImage = mkOption {
      type = types.str;
      default = "ghcr.io/n8n-io/n8n-sandbox-service-api:1.2.0";
      description = "Image for both the certs-bootstrap job and sandbox-api - upstream ships them from the same image, entrypoint override picks the job.";
    };

    runnerImage = mkOption {
      type = types.str;
      default = "ghcr.io/n8n-io/n8n-sandbox-service-runner-dind:1.2.0";
      description = "Image for sandbox-runner-1.";
    };

    sandboxImage = mkOption {
      type = types.str;
      default = "ghcr.io/n8n-io/n8n-sandbox-service-sandbox:latest";
      description = ''
        SANDBOX_RUNNER_DOCKER_SANDBOX_IMAGE: the image sandbox-runner-1 launches per code
        execution, not a container this module runs directly - upstream's own reference stack
        leaves this floating on :latest (no pinned tag is published for it), so this inherits
        that rather than pinning to something that doesn't exist.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.MODULES.security.sops.enable;
        message = "MODULES.services.n8n-sandbox needs MODULES.security.sops.enable: the api/registration/runner keys shared between sandbox-api and sandbox-runner-1 come from sops, with no unauthenticated fallback.";
      }
    ];

    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";

    # oci-containers/`docker run` only accepts one --network at container creation, so - same as
    # mcp-agents-network.nix - the network is created out-of-band rather than declared on either
    # container. A separate network from mcp-agents: nothing here needs to talk to n8n or Context
    # Forge by container name, only sandbox-api and sandbox-runner-1 need to reach each other.
    systemd.services.n8n-sandbox-network = {
      description = ''Create the "${network}" Docker bridge network'';
      after = ["docker.service"];
      requires = ["docker.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.docker}/bin/docker network inspect ${network} >/dev/null 2>&1 || \
          ${pkgs.docker}/bin/docker network create ${network}
      '';
    };

    sops.secrets = {
      ${apiKeySecret} = {};
      ${registrationTokenSecret} = {};
      ${runnerKeySecret} = {};
    };

    sops.templates."n8n-sandbox-api.env" = {
      content = ''
        SANDBOX_API_KEYS=${config.sops.placeholder.${apiKeySecret}}
        SANDBOX_API_RUNNER_REGISTRATION_TOKEN=${config.sops.placeholder.${registrationTokenSecret}}
        SANDBOX_API_RUNNER_API_KEY=${config.sops.placeholder.${runnerKeySecret}}
      '';
      restartUnits = ["sandbox-api.service"];
    };

    sops.templates."n8n-sandbox-runner.env" = {
      content = ''
        SANDBOX_RUNNER_REGISTRATION_TOKEN=${config.sops.placeholder.${registrationTokenSecret}}
        SANDBOX_RUNNER_API_KEYS=${config.sops.placeholder.${runnerKeySecret}}
      '';
      restartUnits = ["sandbox-runner-1.service"];
    };

    # bootstrap-mtls.sh has no idempotent/--force mode of its own, so this only runs the actual
    # generation once (guarded by ca.crt already existing in the volume) - otherwise every
    # rebuild would mint a fresh CA that sandbox-api and sandbox-runner-1's already-mounted certs
    # no longer chain to, breaking their mTLS handshake until both are recreated too.
    systemd.services.n8n-sandbox-certs = {
      description = "Bootstrap mTLS certs for the n8n sandbox stack";
      after = ["docker.service" "n8n-sandbox-network.service"];
      requires = ["docker.service" "n8n-sandbox-network.service"];
      before = ["sandbox-api.service"];
      requiredBy = ["sandbox-api.service"];
      path = [pkgs.docker];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        if docker run --rm -v ${tlsVolume}:/tls ${cfg.serviceImage} test -f /tls/api/ca.crt; then
          exit 0
        fi
        docker run --rm --user 0:0 -v ${tlsVolume}:/tls -e NUM_RUNNERS=1 \
          --entrypoint sh ${cfg.serviceImage} -c '
            bootstrap-mtls.sh --out-dir /tls --api-san sandbox-api \
              --control-san-prefix sandbox-runner --world-readable &&
            chown -R sandbox-api:sandbox-api /tls/api &&
            chmod -R a+rX /tls
          '
      '';
    };

    virtualisation.oci-containers.containers.sandbox-api = {
      image = cfg.serviceImage;
      serviceName = "sandbox-api";
      volumes = ["${tlsVolume}:/tls:ro"];
      # Loopback-only: n8n reaches this over 127.0.0.1 since it runs with --network=host itself
      # (see n8n.nix) rather than on this module's dedicated bridge - only sandbox-runner-1 needs
      # container-name resolution, over ${network}.
      ports = ["127.0.0.1:${toString config.PORTS.n8nSandbox}:8080"];
      environment = {
        SANDBOX_API_GRPC_TLS_CERT_FILE = "/tls/api/grpc-server.crt";
        SANDBOX_API_GRPC_TLS_KEY_FILE = "/tls/api/grpc-server.key";
        SANDBOX_API_GRPC_TLS_CLIENT_CA_FILE = "/tls/api/ca.crt";
        SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_CA_FILE = "/tls/api/ca.crt";
        SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_CERT_FILE = "/tls/api/control-grpc-api-client.crt";
        SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_KEY_FILE = "/tls/api/control-grpc-api-client.key";
        SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_SERVER_NAME = "sandbox-runner-1";
      };
      environmentFiles = [config.sops.templates."n8n-sandbox-api.env".path];
      extraOptions = ["--network=${network}"];
    };

    # Privileged Docker-in-Docker - see the enable option's doc comment. Started only after
    # sandbox-api's unit is up; a startup race past that (sandbox-api's process itself not yet
    # ready) is left to systemd's normal restart-on-failure rather than an explicit health-check
    # wait, same tradeoff this repo already makes for other multi-container ordering.
    virtualisation.oci-containers.containers.sandbox-runner-1 = {
      image = cfg.runnerImage;
      serviceName = "sandbox-runner-1";
      volumes = ["${tlsVolume}:/tls:ro"];
      environment = {
        SANDBOX_RUNNER_API_GRPC_ADDR = "sandbox-api:9090";
        SANDBOX_RUNNER_HTTP_BASE_URL = "http://sandbox-runner-1:8080";
        SANDBOX_RUNNER_CONTROL_GRPC_LISTEN_ADDR = ":9091";
        SANDBOX_RUNNER_CONTROL_GRPC_ADVERTISE_ADDR = "sandbox-runner-1:9091";
        SANDBOX_RUNNER_ID = "runner-1";
        SANDBOX_RUNNER_DOCKER_SANDBOX_IMAGE = cfg.sandboxImage;
        SANDBOX_RUNNER_REGISTRATION_GRPC_CA_FILE = "/tls/runner/ca.crt";
        SANDBOX_RUNNER_REGISTRATION_GRPC_CERT_FILE = "/tls/runner/grpc-client.crt";
        SANDBOX_RUNNER_REGISTRATION_GRPC_KEY_FILE = "/tls/runner/grpc-client.key";
        SANDBOX_RUNNER_REGISTRATION_GRPC_SERVER_NAME = "sandbox-api";
        SANDBOX_RUNNER_CONTROL_GRPC_TLS_CERT_FILE = "/tls/runner/control-grpc-server.crt";
        SANDBOX_RUNNER_CONTROL_GRPC_TLS_KEY_FILE = "/tls/runner/control-grpc-server.key";
        SANDBOX_RUNNER_CONTROL_GRPC_TLS_CLIENT_CA_FILE = "/tls/runner/ca.crt";
      };
      environmentFiles = [config.sops.templates."n8n-sandbox-runner.env".path];
      extraOptions = ["--network=${network}" "--privileged"];
    };

    systemd.services.sandbox-runner-1 = {
      after = ["sandbox-api.service"];
      requires = ["sandbox-api.service"];
    };
  };
}
