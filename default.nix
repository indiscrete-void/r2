let
  pkgs = import <nixpkgs> {};
in
pkgs.haskellPackages.developPackage {
  root = ./.;
  source-overrides = {
    polysemy-transport = ../polysemy-transport;
  };

  modifier = drv:
    pkgs.haskell.lib.addBuildTools drv (with pkgs.haskellPackages;
      [ cabal-install
        haskell-language-server
      ]);
}
