{
    description = "Wayland development shell";

    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs";
    };

    outputs = { self, nixpkgs }:
        let
            system = "x86_64-linux";
            pkgs = import nixpkgs { inherit system; };
        in
            {
            devShells.${system}.default = pkgs.mkShell {
                packages = with pkgs; [
                    wayland
                    wayland-scanner
                    wayland-protocols
                    pkg-config
                ];
            };
            packages.${system}.default = pkgs.stdenv.mkDerivation {
                src = pkgs.lib.cleanGit ./.;
            };
        };
}
