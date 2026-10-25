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
    # Upstream tracks nixos-unstable and builds its Python env with uv2nix against it, so it
    # follows this flake's unstable pin rather than the 26.05 one the hosts run on.
    # PLAN.md §6: firecracker microVMs. Follows this flake's nixpkgs so VM guests and the
    # host share one package set (microvm's modules are overlays on stock NixOS options).
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
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
