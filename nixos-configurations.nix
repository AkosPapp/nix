{ nixpkgs, system, pkgs, pkgs-unstable, home-manager, ... }: {

    laptop = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system pkgs pkgs-unstable home-manager; };
        modules = [ ./generated.nix ./hosts/laptop ];
    };
    

    server1 = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system pkgs pkgs-unstable home-manager; };
        modules = [ ./generated.nix ./hosts/server1 ];
    };
    
}
