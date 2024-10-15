let
  pkgs = import <nixpkgs> {};
in
pkgs.haskellPackages.developPackage {
  root = ./.;
  source-overrides = {
    polysemy-transport = fetchGit {
      url = "https://gitlab.com/indiscrete_void/polysemy-transport.git";
      rev = "db25695b1e1bf52424633bb230d5c785b9802338";
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
