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
    nixpkgs.url = "nixpkgs/nixos-25.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    disko,
    sops-nix,
    deploy-rs,
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

    # Generate options JSON for each configuration
    mkOptionsDoc = name: config: let
      optionsDoc = pkgs-unstable.nixosOptionsDoc {
        options = config.options;
        transformOptions = opt:
          opt
          // {
            # Make declarations relative to nixpkgs for cleaner output
            declarations =
              map (
                decl:
                  nixpkgs.lib.removePrefix (toString nixpkgs + "/") (toString decl)
              )
              opt.declarations;
          };
      };
    in {
      inherit name;
      json = "${optionsDoc.optionsJSON}/share/doc/nixos/options.json";
    };

    # Generate docs for all configurations
    allOptionsDocs = nixpkgs.lib.mapAttrsToList mkOptionsDoc self.nixosConfigurations;
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
              ;
            CONFIGS = self.nixosConfigurations;
          }
          // inputs;
        modules =
          [
            ./hosts/${host}
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
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
      self.nixosConfigurations;

    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;

    #packages.${system}.default =
    #  pkgs-unstable.stdenv.mkDerivation
    #  {
    #    pname = "hello";
    #    version = "1.0.0";
    #    phases = ["installPhase"];

    #    installPhase =
    #      [
    #        ''
    #          mkdir -p $out
    #          echo ${./.}
    #          echo "${nixpkgs.lib.concatStringsSep "\n" module_files}" > "$out/file-list.txt"

    #        ''
    #      ]
    #      ++ (nixpkgs.lib.attrsets.mapAttrsToList
    #        (
    #          name: config: ''
    #            echo "${config.config.environment.blcr.enable}"

    #            exit 1
    #              echo "${
    #              builtins.toJSON
    #              (
    #                #builtins.intersectAttrs
    #                #(
    #                nixpkgs.lib.attrsets.genAttrs
    #                [
    #                  "MODULES"
    #                  "PROFILES"
    #                  "USERS"
    #                  #"_module"
    #                  #"appstream"
    #                  #"assertions"
    #                  #"boot"
    #                  #"console"
    #                  #"containers"
    #                  #"disko"
    #                  #"docker-containers"
    #                  #"documentation"
    #                  #"dysnomia"
    #                  #"ec2"
    #                  "environment"
    #                  #"fileSystems"
    #                  #"fonts"
    #                  #"gtk"
    #                  #"hardware"
    #                  #"i18n"
    #                  #"ids"
    #                  #"image"
    #                  #"isSpecialisation"
    #                  #"jobs"
    #                  #"krb5"
    #                  #"lib"
    #                  #"location"
    #                  #"meta"
    #                  #"minifyStaticFiles"
    #                  #"nesting"
    #                  #"networking"
    #                  #"niri-flake"
    #                  #"nix"
    #                  #"nixops"
    #                  #"nixpkgs"
    #                  #"oci"
    #                  #"openstack"
    #                  #"passthru"
    #                  #"power"
    #                  #"powerManagement"
    #                  #"programs"
    #                  #"qt"
    #                  #"qt5"
    #                  #"security"
    #                  #"services"
    #                  #"snapraid"
    #                  #"sops"
    #                  #"sound"
    #                  #"specialisation"
    #                  #"stubby"
    #                  #swapDevices"
    #                  #system"
    #                  #systemd"
    #                  #time"
    #                  #users"
    #                  #"virtualisation"
    #                  #warnings"
    #                  #xdg"
    #                  #zramSwap"
    #                ]
    #                (a: config.options.${a})
    #                #)
    #                #config.config
    #              )
    #            }" > "$out/${name}.json"

    #              echo "${
    #              builtins.toJSON (nixpkgs.lib.attrsets.mapAttrsToList (k: v: k) config.options)
    #            }" > "$out/${name}.json2"
    #          ''
    #        )
    #        self.nixosConfigurations);
    #  };
    # Default package that generates options.json for all configurations
    # packages.${system}.default =
    #   pkgs-unstable.runCommand "nixos-options-all" {
    #     nativeBuildInputs = [pkgs-unstable.jq];
    #   } ''
    #     mkdir -p $out

    #     ${nixpkgs.lib.concatMapStringsSep "\n" (
    #         doc: let
    #           params = pkgs-unstable.lib.importJSON doc.json;

    #           params_filtered1 =
    #             pkgs-unstable.lib.filterAttrs
    #             (
    #               a: b: (pkgs-unstable.lib.hasAttr "default" b)
    #             )
    #             params;

    #           params_filtered2 =
    #             pkgs-unstable.lib.filterAttrs
    #             (
    #               a: b: (pkgs-unstable.lib.hasAttr "type" b)
    #             )
    #             params_filtered1;

    #           params_filtered3 =
    #             pkgs-unstable.lib.filterAttrs
    #             (
    #               a: b: (pkgs-unstable.lib.hasAttrByPath b.loc self.nixosConfigurations.${doc.name}.options)
    #             )
    #             params_filtered2;

    #           vals = (
    #             builtins.mapAttrs (
    #               k: v: {
    #                 meta = v;
    #                 l = v.loc;
    #                 val =
    #                   pkgs-unstable.lib.typeOf
    #                   (
    #                     pkgs-unstable.lib.attrsets.attrByPath
    #                     v.loc
    #                     null
    #                     self.nixosConfigurations.${doc.name}.config
    #                   );
    #               }
    #             )
    #             params_filtered3
    #           );
    #           options = self.nixosConfigurations.${doc.name}.options;
    #           file = builtins.toFile "json" (builtins.toJSON vals);
    #         in ''
    #           echo cp ${doc.json} $out/${doc.name}-options.json
    #           cp ${doc.json} $out/${doc.name}-options.json
    #           echo cp ${file} $out/${doc.name}-options-processed.json
    #           cp ${file} $out/${doc.name}-options-processed.json
    #         ''
    #       )
    #       allOptionsDocs}
    #   '';
  };
}
