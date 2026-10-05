{
  description = "Barcode Product Desk: a server-rendered RabbitMQ product desk";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      source = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./bpd.cabal ./cabal.project ./LICENSE ./app ./src ./test
        ];
      };
      packageFor = pkgs: pkgs.haskell.lib.justStaticExecutables
        (pkgs.haskellPackages.callPackage ./nix/package.nix { src = source; });
      module = import ./nix/module.nix { inherit packageFor; };
    in {
      packages = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
            bpd = packageFor pkgs;
        in { inherit bpd; default = bpd; });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.bpd}/bin/bpd";
          meta.description = "Barcode Product Desk";
        };
      });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in { default = pkgs.haskellPackages.shellFor {
          packages = hp: [ (hp.callPackage ./nix/package.nix { src = source; }) ];
          nativeBuildInputs = [ pkgs.cabal-install pkgs.haskell-language-server ];
        }; });

      nixosModules = { bpd = module; default = module; };

      checks = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          package = self.packages.${system}.bpd;
          integration = pkgs.testers.runNixOSTest (import ./nix/test.nix {
            inherit pkgs module;
            bpd = self.packages.${system}.bpd;
          });
        });
    };
}
