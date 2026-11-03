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
      lib = nixpkgs.lib;

      # The package's own files: the top-level yt*.el, without the tests.
      ytSrc = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.difference (lib.fileset.fileFilter (
          f: f.hasExt "el" && lib.hasPrefix "yt" f.name && !(lib.hasSuffix "-autoloads.el" f.name)
        ) ./.) ./test;
      };

      # The version, from the Version header of yt.el.
      version = lib.removePrefix ";; Version: " (
        lib.findFirst (lib.hasPrefix ";; Version: ") (throw "yt.el has no Version header") (
          lib.splitString "\n" (builtins.readFile ./yt.el)
        )
      );

      # yt as an Emacs package, for the emacsPackages set EPKGS.  The
      # cookie exporter is found by its store path, not on PATH, which an
      # Emacs daemon started by systemd may not have.
      mkYt =
        pkgs: epkgs:
        epkgs.trivialBuild {
          pname = "yt";
          inherit version;
          src = ytSrc;
          turnCompilationWarningToError = true;
          postPatch = ''
            substituteInPlace yt.el --replace-fail \
              '(defcustom yt-export-cookies-program "yt-export-cookies"' \
              '(defcustom yt-export-cookies-program "${mkExporter pkgs}/bin/yt-export-cookies"'
          '';
          # Install the way package.el would, with autoloads, so that Emacs
          # activates yt at startup and M-x yt works without a require.
          installPhase = ''
            runHook preInstall
            dir=$out/share/emacs/site-lisp/elpa/yt-${version}
            install -d $dir
            install *.el *.elc $dir
            cat > $dir/yt-pkg.el <<'PKG'
            ;;; yt-pkg.el --- Package description for yt -*- no-byte-compile: t -*-
            (define-package "yt" "${version}" "Browse and play your YouTube subscriptions" '((emacs "30.1")))
            PKG
            emacs --batch --eval "(loaddefs-generate \"$dir\" \"$dir/yt-autoloads.el\")"
            runHook postInstall
          '';
          meta = {
            description = "Browse and play your YouTube subscriptions in Emacs";
            license = lib.licenses.gpl3Plus;
          };
        };

      mkExporter =
        pkgs:
        pkgs.writers.writePython3Bin "yt-export-cookies" {
          libraries = with pkgs.python3Packages; [
            yt-dlp
            secretstorage
          ];
        } (builtins.readFile ./bin/yt-export-cookies.py);

      # What a host needs at runtime besides yt-dlp and vlc.
      mkRuntime =
        pkgs:
        pkgs.buildEnv {
          name = "yt-runtime";
          paths = [
            pkgs.mpv
            (mkExporter pkgs)
          ];
        };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          # The only Emacs used for builds and tests; never the host Emacs.
          # embark and marginalia are only on its load path, for the tests of
          # yt's optional integrations; nothing loads them by default.
          emacs-test = (pkgs.emacsPackagesFor pkgs.emacs30-pgtk).emacsWithPackages (epkgs: [
            epkgs.package-lint
            epkgs.embark
            epkgs.marginalia
          ]);

        in
        {
          inherit emacs-test;
          yt-export-cookies = mkExporter pkgs;
          runtime = mkRuntime pkgs;
          # yt, byte-compiled with the Emacs of the test setup.
          default = mkYt pkgs (pkgs.emacsPackagesFor pkgs.emacs30-pgtk);
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
              # yt's state, the cookies included, lives outside the checkout,
              # where no build, archive or indexer of the repository finds it.
              real_state="''${XDG_STATE_HOME:-$HOME/.local/state}"
              state="$real_state/yt-sandbox"
              cache="''${XDG_CACHE_HOME:-$HOME/.cache}/yt-sandbox"
              mkdir -p "$sb/emacs.d" "$state" "$cache"
              chmod 0700 "$state" "$cache"
              if [ -d "$sb/state" ]; then
                echo "yt-sandbox: its state moved out of the checkout, to $state." >&2
                echo "  To keep the sandbox signed in: mv '$sb/state/yt' '$state/'" >&2
                echo "  Then delete '$sb/state' and '$sb/cache'." >&2
              fi
              # Only state and cache are redirected: XDG_CONFIG_HOME must stay
              # real so the Chromium profile can be found.
              export XDG_STATE_HOME="$state" XDG_CACHE_HOME="$cache"
              export YT_SANDBOX_REAL_STATE="$real_state/yt"
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
          load-check = makeCheck "load-check";
          checkdoc = makeCheck "checkdoc";
          lint = makeCheck "lint";
          test = makeCheck "test";
          # The tests again with byte-compiled code, which runs faster and
          # has caught races the interpreted run hides.
          test-compiled = makeCheck "compile test";
          package = p.default;
          inherit (p) yt-export-cookies;
        }
      );

      # Adds yt to every emacsPackages set (as `yt'), plus yt-el (yt for
      # pkgs.emacs), yt-export-cookies and yt-runtime.
      overlays.default = final: prev: {
        emacsPackagesFor =
          emacs: (prev.emacsPackagesFor emacs).overrideScope (efinal: _: { yt = mkYt final efinal; });
        yt-el = (final.emacsPackagesFor final.emacs).yt;
        yt-export-cookies = mkExporter final;
        yt-runtime = mkRuntime final;
      };

      # Home Manager module.  `programs.yt.enable' installs mpv and the
      # cookie exporter (yt-dlp and VLC are expected from elsewhere);
      # `programs.yt.installElisp' also adds yt to `programs.emacs'.  It
      # does not set nixpkgs.overlays, so it works with useGlobalPkgs.
      homeModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.yt;
        in
        {
          options.programs.yt = {
            enable = lib.mkEnableOption "the programs yt runs: mpv and yt-export-cookies";
            installElisp = lib.mkEnableOption "yt in `programs.emacs.extraPackages`";
            swayWindowRule = lib.mkEnableOption "a sway rule for mpv's window (app id emacs-yt)";
            swayWindowCommand = lib.mkOption {
              type = lib.types.str;
              default = "floating enable, sticky enable, resize set 960 540";
              description = "The sway command run on mpv's window when `swayWindowRule` is on.";
            };
          };
          config = lib.mkIf cfg.enable (
            lib.mkMerge [
              {
                programs.mpv.enable = lib.mkDefault true;
                home.packages = [ (mkExporter pkgs) ];
              }
              (lib.mkIf cfg.installElisp {
                programs.emacs.extraPackages = epkgs: [ (mkYt pkgs epkgs) ];
              })
              (lib.mkIf cfg.swayWindowRule {
                wayland.windowManager.sway.config.window.commands = [
                  {
                    criteria.app_id = "^emacs-yt$";
                    command = cfg.swayWindowCommand;
                  }
                ];
              })
            ]
          );
        };
    };
}
