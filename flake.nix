{
  description = "Element 0: a small embeddable Lisp for the Zig ecosystem";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, zig-overlay, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          let
            pkgs = import nixpkgs { inherit system; };
            zig = zig-overlay.packages.${system}."0.16.0";
          in
          f pkgs zig
        );
    in
    {
      devShells = forAllSystems (pkgs: zig:
        {
          default = pkgs.mkShell {
            name = "element-0-dev";

            packages = with pkgs; [
              zig
              gnumake
              python313
              uv
              nodejs
              gh
            ];

            ZIG = "${zig}/bin/zig";

            shellHook = ''
              echo "Element 0 development environment"
              echo "Zig: $(zig version 2>/dev/null || echo 'not found')"
              echo "uv: $(uv --version 2>/dev/null || echo 'not found')"
              echo "Node: $(node --version 2>/dev/null || echo 'not found')"
            '';
          };
        });

      formatter = forAllSystems (pkgs: _: pkgs.nixpkgs-fmt);
    };
}
