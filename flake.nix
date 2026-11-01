# Copyright (C) 2026 Erik Sundin
# SPDX-License-Identifier: GPL-3.0-or-later
{
  description = "yt: browse and play your YouTube subscriptions in Emacs";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      packagesFor = pkgs: self.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          # The only Emacs used for builds and tests; never the host Emacs.
          emacs-test = (pkgs.emacsPackagesFor pkgs.emacs30-pgtk).emacsWithPackages (epkgs: [
            epkgs.package-lint
          ]);

          yt-export-cookies = pkgs.writers.writePython3Bin "yt-export-cookies" {
            libraries = with pkgs.python3Packages; [
              yt-dlp
              secretstorage
            ];
          } (builtins.readFile ./bin/yt-export-cookies.py);
        in
        {
          inherit emacs-test yt-export-cookies;

          # What a host needs at runtime besides yt-dlp and vlc.
          runtime = pkgs.buildEnv {
            name = "yt-runtime";
            paths = [
              pkgs.mpv
              yt-export-cookies
            ];
          };
        }
      );

      devShells = forAllSystems (
        pkgs:
        let
          p = packagesFor pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              p.emacs-test
              p.yt-export-cookies
              pkgs.gnumake
              pkgs.git
              pkgs.jq
              pkgs.curl
              pkgs.mpv
              pkgs.yt-dlp
              pkgs.vlc
            ];
            YT_EMACS = "${p.emacs-test}/bin/emacs";
            # A host LD_LIBRARY_PATH can load libraries built against a newer
            # glibc than this nixpkgs (mpv then fails with "GLIBC_2.43 not
            # found"); nothing here needs it.
            shellHook = "unset LD_LIBRARY_PATH";
          };
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          p = packagesFor pkgs;

          # Find the checkout the command was started in; the apps work on
          # the working tree, not on the flake's store copy.
          findRepo = ''
            repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            if [ ! -f "$repo/yt.el" ]; then
              echo "$0: run this from the emacs-yt checkout" >&2
              exit 1
            fi
          '';

          test = pkgs.writeShellApplication {
            name = "yt-test";
            runtimeInputs = [
              pkgs.gnumake
              pkgs.git
              pkgs.coreutils
            ];
            text = ''
              ${findRepo}
              cd "$repo"
              export YT_EMACS=${p.emacs-test}/bin/emacs
              if [ $# -eq 0 ]; then set -- test; fi
              exec make "$@"
            '';
          };

          sandbox = pkgs.writeShellApplication {
            name = "yt-sandbox";
            runtimeInputs = [
              pkgs.git
              pkgs.coreutils
              p.emacs-test
              p.yt-export-cookies
              pkgs.mpv
              pkgs.yt-dlp
              pkgs.vlc
              pkgs.curl
            ];
            text = ''
              ${findRepo}
              : "''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set}"
              # See the dev shell: a host LD_LIBRARY_PATH breaks the flake's mpv.
              unset LD_LIBRARY_PATH
              sb="$repo/.sandbox"
              mkdir -p "$sb/emacs.d" "$sb/state" "$sb/cache"
              chmod 0700 "$sb/state" "$sb/cache"
              # Only state and cache are redirected: XDG_CONFIG_HOME must stay
              # real so the Chromium profile can be found.
              export XDG_STATE_HOME="$sb/state" XDG_CACHE_HOME="$sb/cache"
              export YT_SANDBOX_REPO="$repo"
              export YT_SANDBOX_RUNTIME_DIR="$XDG_RUNTIME_DIR/yt-sandbox"
              # Default Emacs plus yt: -q and --no-site-file skip every host
              # init file (~/.emacs.d, ~/.emacs, default.el, the Nix profiles'
              # site-lisp); the only config is sandbox/init.el.  Emacs keeps
              # its own files in .sandbox/emacs.d.
              exec emacs -q --no-site-file --init-directory="$sb/emacs.d" \
                --name yt-sandbox -l "$repo/sandbox/init.el" "$@"
            '';
          };
        in
        {
          test = {
            type = "app";
            program = "${test}/bin/yt-test";
          };
          sandbox = {
            type = "app";
            program = "${sandbox}/bin/yt-sandbox";
          };
        }
      );

      checks = forAllSystems (
        pkgs:
        let
          p = packagesFor pkgs;
          makeCheck =
            target:
            pkgs.runCommand "yt-${target}"
              {
                nativeBuildInputs = [ pkgs.gnumake ];
                YT_EMACS = "${p.emacs-test}/bin/emacs";
              }
              ''
                cp -r ${self}/. src
                chmod -R u+w src
                cd src
                HOME=$TMPDIR make ${target}
                touch $out
              '';
        in
        {
          compile = makeCheck "compile";
          checkdoc = makeCheck "checkdoc";
          lint = makeCheck "lint";
          test = makeCheck "test";
          inherit (p) yt-export-cookies;
        }
      );
    };
}
