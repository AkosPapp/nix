{ nixpkgs, system, ... }:
{
    laptop = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system; };
        modules = [ ./generated.nix ./hosts/laptop ];
    };
    server1 = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system; };
        modules = [ ./generated.nix ./hosts/server1 ];
    };
}
