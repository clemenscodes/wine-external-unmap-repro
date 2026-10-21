{
  description = "Repro: Wine (winex11) never propagates an external unmap/map of a managed window to the Win32 side";

  # Pinned to a nixpkgs revision that ships Wine 11.19.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/55bfb4d7437bd4e09ab7cba58a43bd68eb310044";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      wine = pkgs.wineWow64Packages.staging;

      # The same Wine with the fix from patches/ applied.
      wine-patched = wine.overrideAttrs (old: {
        pname = "${old.pname}-external-withdraw-fix";
        patches = (old.patches or [ ]) ++ [
          ./patches/0001-winex11-sync-win32-visibility-on-external-withdraw-map.patch
        ];
      });

      tools = [
        pkgs.pkgsCross.mingwW64.buildPackages.gcc
        pkgs.gnumake
        pkgs.xvfb
        pkgs.openbox
        pkgs.xdotool
        pkgs.xwininfo
        pkgs.xprop
        pkgs.xdpyinfo
        pkgs.bc
      ];
    in
    {
      packages.${system} = {
        inherit wine wine-patched;
        default = wine;
      };

      devShells.${system} = {
        # nix develop: the unpatched Wine, shows the bug.
        default = pkgs.mkShell { packages = [ wine ] ++ tools; };
        # nix develop .#patched: the patched Wine, confirms the fix.
        patched = pkgs.mkShell { packages = [ wine-patched ] ++ tools; };
      };
    };
}
