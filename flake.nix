{
  description = "A config for sketchybar that's reproducible and performant";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    sbarlua.url = "github:FelixKratz/SbarLua";
    sbarlua.flake = false;
  };
  outputs = inputs @ {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        config = {allowUnfree = true;};
        overlays = [];
      };
      # dependencies = [
      # pkgs.lua5_4
      # ];
      # mynewlib = pkgs.toLuaModule ( pkgs.mkDerivation { /* ... */ });
      # or pkgs.buildLuaPackage
      # You can see a few examples at pkgs/top-level/lua-packages.nix
      sbar = pkgs.lua54Packages.buildLuaPackage {
        name = "sbar";
        pname = "sbar";
        version = "1";
        src = inputs.sbarlua;
        installPhase = ''
          mkdir -p $out/lib/lua/5.4
          cp bin/sketchybar.so $out/lib/lua/5.4/
        '';
        nativeBuildInputs = with pkgs;
          [gcc readline clang stdenv]
          ++ lib.optionals stdenv.isDarwin
          (with pkgs.darwin.apple_sdk.frameworks; [
            CoreFoundation
          ]);
      };
      sbar-config-libs = pkgs.stdenv.mkDerivation {
        pname = "my-lua-module";
        version = "1.0.0";

        src = ./sbar-config-libs;

        buildInputs = [pkgs.lua5_4];

        # Install Lua files to the correct directory
        installPhase = ''
          mkdir -p $out/share/lua/5.4/sbar-config-libs
          cp -r sbar-config-libs/* $out/share/lua/5.4/sbar-config-libs
        '';
      };

      l = pkgs.lua5_4.withPackages (ps: with ps; [luafilesystem sbar sbar-config-libs]);
      rc = pkgs.writeScript "sketchybarrc" ''
        #!${l}/bin/lua

        -- Require the sketchybar module (sbar above) from https://github.com/FelixKratz/SbarLua/
        sbar = require("sketchybar")

        -- Bundle the entire initial configuration into a single message to sketchybar
        -- This improves startup times drastically, try removing both the begin and end
        -- config calls to see the difference -- yeah..
        sbar.begin_config()
        require("sbar-config-libs/init")
        sbar.hotload(true)
        sbar.end_config()

        -- Run the event loop of the sketchybar module (without this there will be no
        -- callback functions executed in the lua module)
        sbar.event_loop()
      '';
    in rec {
      packages.sketchybar-config = rc;
      packages.default = packages.sketchybar-config;
      devShell = pkgs.mkShell {
        buildInputs = [l rc pkgs.sketchybar];
      };
    });
}
