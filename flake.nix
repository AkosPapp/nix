{
  description = "My Nixos Configuration";

  inputs = {
    deploy-rs.url = "github:serokell/deploy-rs";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    my-nixvim.url = "github:PPAPSONKA/nixvim";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
    nixpkgs.url = "nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri = {
      url = "github:sodiboo/niri-flake/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix_autobuild = {
      url = "github:AkosPapp/nix_autobuild";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # PLAN.md §6: firecracker microVMs. Follows this flake's nixpkgs so VM guests and the
    # host share one package set (microvm's modules are overlays on stock NixOS options).
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Upstream tracks nixos-unstable but their own flake.lock pins 02c087f3fe67; mirror
    # that pin here (2026-11-09) rather than following ours or letting it re-resolve:
    # nixpkgs-unstable f4a03c008967 carries the patchelf 0.19.2 -> 0.15.2 revert, and
    # hermes' nix/pm-packages.nix patches patchelf 0.19.2's source with the unreleased
    # NixOS/patchelf#672 fix - at 0.15.2 that patch fails 4/6 hunks, taking down every pm
    # tool (ripgrep/node/pnpm/ffmpeg) and with them hp's /etc. Bump this rev together
    # with `nix flake update hermes-agent` (take whatever THEIR flake.lock locks).
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";
    };
    # gpu-unlock (tensor-core throttle removal) as of 2026-10-28 only carries Nix packaging in
    # the still-open PR #186, so this pins that PR's head branch, not a release of the repo.
    # modules/hardware/nvidia-gpu-unlock.nix consumes the flake module behind an opt-in flag.
    # Re-point at `github:Zagitta/gpu-unlock` once (if) the PR merges.
    #
    # Rev matters per-CARD, not just per-PR (legion5 measured 2026-10-29): the branch's earlier
    # head was upstream 1.1.0, whose recipes.c covers GA10x + AD102 only, so it booted and
    # logged `gpu_unlock: no supported card at "0000:01:00.0"` for the RTX 4060 Laptop
    # (10de:28e0). The 2.0.0 rebase added AD107. When a card says "no supported card", check
    # kernel/gpu_unlock/recipes.c in THIS input for its device id before blaming power timing:
    #   nix-instantiate --eval --expr '<gpu-unlock>/kernel/gpu_unlock/recipes.c' --raw | grep 28e0
    gpu-unlock = {
      url = "github:bearice/gpu-unlock/nix-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    deploy-rs,
    disko,
    microvm,
    nix_autobuild,
    nixpkgs,
    nixpkgs-unstable,
    self,
    sops-nix,
    ...
  } @ inputs: let
    nixos-version = builtins.elemAt (builtins.match "([0-9][0-9]\.[0-9][0-9]).*" inputs.nixpkgs.lib.version) 0;

    system = "x86_64-linux";

    # No allowBroken (2026-10-24 audit #7): a package nixpkgs marks broken has a build that
    # is known to fail, and permitting it globally pins the flake silently to those failures.
    # immich.nix keeps its own scoped import for the CUDA worker.
    pkgs-unstable = import nixpkgs-unstable {
      inherit system;
      config = {
        allowUnfree = true;
      };
    };

    # Hosts are directories with a default.nix; hosts/vms/ (guest configs, no
    # default.nix) is the only non-machine directory.
    hosts =
      nixpkgs.lib.filterAttrs
      (name: type: type == "directory" && nixpkgs.lib.pathExists ./hosts/${name}/default.nix)
      (builtins.readDir ./hosts);

    module_files =
      builtins.filter
      (path: nixpkgs.lib.hasSuffix ".nix" (builtins.toString path))
      (
        (nixpkgs.lib.filesystem.listFilesRecursive ./modules)
        ++ (nixpkgs.lib.filesystem.listFilesRecursive ./profiles)
        ++ (nixpkgs.lib.filesystem.listFilesRecursive ./users)
      );
  in {
    formatter.${system} = nixpkgs.legacyPackages.${system}.alejandra;

    # `nix run .#cloudflare-config` - the whole Cloudflare one-time setup (login, tunnel,
    # sops secrets, UUID into the host config, DNS routes) in one rerunnable command;
    # rerunning it is also how the secrets are refreshed. packages/cloudflare-config.sh.
    apps.${system}.cloudflare-config = {
      type = "app";
      program = let
        pkgs = nixpkgs.legacyPackages.${system};
      in "${pkgs.writeShellApplication {
        name = "cloudflare-config";
        runtimeInputs = [
          pkgs.git
          pkgs.cloudflared
          pkgs.jq
          pkgs.nix
          pkgs.sops
        ];
        text = builtins.readFile ./packages/cloudflare-config.sh;
      }}/bin/cloudflare-config";
    };

    nixosConfigurations =
      builtins.mapAttrs (host: _: (nixpkgs.lib.nixosSystem {
        specialArgs =
          {
            inherit
              pkgs-unstable
              system
              nixos-version
              inputs
              ;
            nixosConfigurations = self.nixosConfigurations;
            # PLAN.md §6: microVM configs for modules/vm/microvm-host.nix (self-reference,
            # lazy - hosts that disable the microvm host never force it).
            microvmConfigurations = self.microvmConfigurations;
            configName = host;
          }
          // inputs;
        modules =
          [
            ./hosts/${host}
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            nix_autobuild.nixosModules.nix_autobuild
            inputs.hermes-agent.nixosModules.default
          ]
          ++ module_files;
      }))
      hosts;

    # PLAN.md §6: firecracker guests live here, NOT in nixosConfigurations - deploy-rs
    # iterates nixosConfigurations and must never try to ssh-activate a VM from the host
    # list; the microvm host module starts them from its side.
    microvmConfigurations = {
      vm-agents = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit system inputs;
          pkgs-unstable = null; # guests never reference the unstable set
          nixos-version = nixos-version;
          nixosConfigurations = {};
          microvmConfigurations = {};
          configName = "vm-agents";
        };
        modules = [./hosts/vms/vm-agents.nix];
      };
    };

    deploy.nodes =
      builtins.mapAttrs (host: config: {
        hostname = host;
        # The magic-rollback waiter starts counting when activation begins, and hp's
        # unit-start phase (postgres, docker-coroot, ollama, the microVMs, ...) runs
        # well past deploy-rs' 30s default - a healthy 2026-10-26 switch was rolled
        # back for taking ~2min. 10min keeps the safety net without eating itself.
        confirmTimeout = 600;
        profiles.system = {
          sshUser = "root";
          user = "root";
          path = deploy-rs.lib.${system}.activate.nixos config;
          # Build on the target (hp is fast enough and already has the substitutes; the laptop
          # does not have to ship the closure).
          remoteBuild = true;
        };
      })
      (nixpkgs.lib.attrsets.filterAttrs (name: _: name != "iso") self.nixosConfigurations);

    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
