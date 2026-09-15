{
  description = "Run Autodesk Fusion 360 on Nix / NixOS via Wine";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    flake-compat.url = "https://git.lix.systems/lix-project/flake-compat/archive/main.tar.gz";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      packages.${system} = {
        fusion360 = pkgs.callPackage ./pkgs/fusion360/package.nix { };
        default = self.packages.${system}.fusion360;
      };

      apps.${system} = {
        fusion360 = {
          type = "app";
          program = "${self.packages.${system}.fusion360}/bin/fusion360";
          meta = self.packages.${system}.fusion360.meta;
        };
        default = self.apps.${system}.fusion360;
      };

      overlays.default = import ./overlay.nix;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixpkgs-fmt
          shellcheck
        ];
      };

      checks.${system}.fusion360 = self.packages.${system}.fusion360;
    };
}
