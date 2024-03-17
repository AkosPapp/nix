{ nixpkgs, system, pkgs, pkgs-unstable, home-manager, ... }: {

    laptop = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system pkgs pkgs-unstable home-manager; };
        modules = [ ./generated.nix ./hosts/laptop
        home-manager.nixosModules.home-manager
        {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
        }
        ];
    };
    

    server1 = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system pkgs pkgs-unstable home-manager; };
        modules = [ ./generated.nix ./hosts/server1
        home-manager.nixosModules.home-manager
        {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
        }
        ];
    };
    
}
