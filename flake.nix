{
  description = "linux-mcp-server: read-only Linux diagnostics over MCP, locally or over SSH";

  # Pinned to the same nixpkgs revision devenv resolves in this sandbox, so the
  # Python dependency closure is already in the store and nothing rebuilds.
  # Bump with: nix flake update
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/54ba4bcec4043e72a4006d825e0d7aff5562008f";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: _prev: {
        linux-mcp-server = final.callPackage ./package.nix { };
      };

      packages = forAllSystems (pkgs: rec {
        default = linux-mcp-server;

        linux-mcp-server = pkgs.callPackage ./package.nix { };

        # Same server plus Kerberos/GSSAPI SSH auth.
        linux-mcp-server-gssapi = pkgs.callPackage ./package.nix { withGssapi = true; };
      });

      apps = forAllSystems (pkgs: rec {
        default = linux-mcp-server;

        linux-mcp-server = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.linux-mcp-server;
        };
      });

      checks = forAllSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) linux-mcp-server;
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
