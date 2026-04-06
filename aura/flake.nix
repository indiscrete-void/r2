{
  description = "Idris2 with zsh";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ idris2 zsh ];
          shellHook = ''
            if [ -z "$ZSH_VERSION" ]; then
              echo "Idris2 ${pkgs.idris2.version}"
              exec zsh
            fi
          '';
        };
      });
}
