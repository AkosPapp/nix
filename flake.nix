{
  description = "My Nixos Configuration";

  inputs = {
    deploy-rs.url = "github:serokell/deploy-rs";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    my-nixvim. url = "github:PPAPSONKA/nixvim";
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
    # Not following our nixpkgs: upstream packages it with uv2nix against unstable and calls the
    # flake best-effort, so its own lock is the combination it was actually built against.
    hermes-agent.url = "github:NousResearch/hermes-agent";
    mcp-switchboard.url = "github:AkosPapp/mcp-switchboard";
  };

  outputs = {
    deploy-rs,
    disko,
    nix_autobuild,
    nixpkgs,
    nixpkgs-unstable,
    self,
    sops-nix,
    ...
  } @ inputs: let
    nixos-version = builtins.elemAt (builtins.match "([0-9][0-9]\.[0-9][0-9]).*" inputs.nixpkgs.lib.version) 0;

    system = "x86_64-linux";

    pkgs-unstable = import nixpkgs-unstable {
      inherit system;
      config = {
        allowUnfree = true;
        allowBroken = true;
      };
    };

    hosts = builtins.readDir ./hosts;

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

    deploy.nodes =
      builtins.mapAttrs (host: config: {
        hostname = host;
        profiles.system = {
          sshUser = "root";
          user = "root";
          path = deploy-rs.lib.${system}.activate.nixos config;
          remoteBuild = false;
        };
      })
      (nixpkgs.lib.attrsets.filterAttrs (name: _: name != "iso") self.nixosConfigurations);

    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
