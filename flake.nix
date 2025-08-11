{
  description = "Claude Desktop for Linux";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }: flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system: let
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    packages = rec {
      patchy-cnb = pkgs.callPackage ./pkgs/patchy-cnb.nix {};
      claude-desktop = pkgs.callPackage ./pkgs/claude-desktop.nix {
        inherit patchy-cnb;
      };
      
      claude-desktop-with-fhs = let
        fhsPackage = pkgs.buildFHSEnv {
          name = "claude-desktop-fhs";
          targetPkgs = pkgs: with pkgs; [
            self.packages.${system}.claude-desktop
            docker
            glibc
            openssl
            nodejs
            uv
          ];
          runScript = "${self.packages.${system}.claude-desktop}/bin/claude-desktop";
        };
        desktopFile = pkgs.makeDesktopItem {
          name = "claude-desktop-fhs";
          desktopName = "Claude (FHS)";
          genericName = "Claude Desktop";
          exec = "claude-desktop-fhs %u";
          icon = "claude";
          categories = [ "Office" "Utility" ];
        };
      in pkgs.runCommand "claude-desktop-fhs-with-desktop" {
        nativeBuildInputs = [ pkgs.makeWrapper desktopFile ];
      } ''
        mkdir -p $out/share/applications
        ln -s ${desktopFile}/share/applications/claude-desktop-fhs.desktop $out/share/applications/claude-desktop-fhs.desktop
        
        mkdir -p $out/bin
        makeWrapper ${fhsPackage}/bin/claude-desktop $out/bin/claude-desktop-fhs \
          --prefix XDG_DATA_DIRS : "$out/share:${self.packages.${system}.claude-desktop}/share"
      '';
      
      default = claude-desktop;
    };
  });
}
