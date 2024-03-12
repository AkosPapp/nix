{ nixpkgs, system, pkgs, pkgs-unstable, ... }: {

    laptop = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system pkgs pkgs-unstable; };
        modules = [ ./generated.nix ./hosts/laptop ];
    };
    

    server1 = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system pkgs pkgs-unstable; };
        modules = [ ./generated.nix ./hosts/server1 ];
    };
    
}
