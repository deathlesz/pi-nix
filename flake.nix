{
  description = "Pi coding agent with declarative extensions, MCP servers, tools, and settings";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      piNix = import ./lib { lib = nixpkgs.lib; };

      # The build of `config.nix` at the repository root.
      mkDefaultPi =
        system:
        let
          pkgs = pkgsFor system;
        in
        piNix.mkPi pkgs (import ./config.nix { inherit pkgs; });
    in
    {
      # Reusable library: `pi-nix.lib.mkPi pkgs { ... }` builds a Pi environment
      # from any configuration attrset, without this flake's config.nix.
      lib = piNix;

      packages = forAllSystems (system: {
        pi = mkDefaultPi system;
        default = self.packages.${system}.pi;
      });

      # `nix flake check` builds the default environment and checks the
      # library's normalization and validation (no network required).
      checks = forAllSystems (system: {
        pi = self.packages.${system}.pi;
        lib = import ./tests/lib-test.nix {
          pkgs = pkgsFor system;
          inherit piNix;
        };
      });

      apps = forAllSystems (system: {
        pi = {
          type = "app";
          program = "${self.packages.${system}.pi}/bin/pi";
        };
        # Applies config.nix to the Pi config directory and installs any missing
        # packages, without starting Pi. Useful for provisioning and CI.
        pi-reconcile = {
          type = "app";
          program = "${self.packages.${system}.pi}/bin/pi-reconcile";
        };
        default = self.apps.${system}.pi;
      });

      devShells = forAllSystems (system: {
        default = (pkgsFor system).mkShell {
          packages = [ self.packages.${system}.pi ];
          shellHook = ''
            echo "pi-nix dev shell — run \`pi\` (management: \`pi-reconcile\`)"
          '';
        };
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      # NixOS / home-manager integration:
      #   imports = [ pi-nix.homeManagerModules.default ];
      #   programs.pi-nix = { enable = true; config = { extensions = [ ... ]; }; };
      homeManagerModules = {
        default = import ./modules/home-manager.nix;
        pi-nix = self.homeManagerModules.default;
      };

      nixosModules = {
        default = import ./modules/nixos.nix;
        pi-nix = self.nixosModules.default;
      };
    };
}
