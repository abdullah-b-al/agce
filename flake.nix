{
  description = "Wayland development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          wineWow64Packages.stable

          wayland
          wayland-scanner
          wayland-protocols
          pkg-config
          libGL
          libglvnd
          mesa
          libgbm
        ];
      };
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        src = pkgs.lib.cleanGit ./.;
      };
    };
}
