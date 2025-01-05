let
  pkgs = import <nixpkgs> {};
in
pkgs.haskellPackages.developPackage {
  root = ./.;
  source-overrides = {
    polysemy-transport = fetchGit {
      url = "https://gitlab.com/indiscrete_void/polysemy-transport.git";
      rev = "1d1c32909fde548a19d84daaf705ab7e8ba4db97";
    };

    polysemy-scoped-process = fetchGit {
      url = "https://gitlab.com/indiscrete_void/polysemy-scoped-process.git";
      rev = "c1214a10362e62d1368aa94820e0faecdb878776";
    };
  };

  modifier = drv:
    pkgs.haskell.lib.addBuildTools drv (with pkgs.haskellPackages;
      [ cabal-install
        haskell-language-server
      ]);
}
