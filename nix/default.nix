# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  sourceInfo ? { },
}:
let
  inherit (pkgs) lib;
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "guix-impurifier";
  };
  registerRoot = import ./register-root.nix { inherit pkgs; };
  sdk = pkgs.linkFarm "guix-impurifier-sdk" [
    {
      name = "python";
      path = pkgs.python3;
    }
    {
      name = "nix";
      path = pkgs.nix;
    }
    {
      name = "register-root";
      path = registerRoot;
    }
  ];
  package = pkgs.writeShellApplication {
    name = "guix-impurifier";
    runtimeInputs = [
      pkgs.guix
      pkgs.nix
      pkgs.python3
      registerRoot
    ];
    text = ''
      case "''${1:-}" in
        prune) shift; exec ${sdk}/python/bin/python3 ${../src/prune.py} ;;
        prepare) shift; exec ${sdk}/python/bin/python3 ${../src/prepare.py} "$@" ;;
        *) echo 'usage: guix-impurifier prepare [--owner USER] GUIX_STORE_PACKAGE' >&2; exit 2 ;;
      esac
    '';
  };
  makePackage =
    {
      pkg,
      program ? pkg.meta.mainProgram or pkg.pname,
      offline ? false,
      hardware ? null,
    }:
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9_+-][A-Za-z0-9_.+-]*" program != null
    ) "invalid application program";
    assert lib.assertMsg (
      hardware == null || lib.elem program (hardware.programs or [ ])
    ) "hardware must select this program";
    pkgs.runCommand "${pkg.pname}-${pkg.version}-guix"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        mkdir -p $out/payload/bin
        cp ${../src/launch.py} $out/payload/launch.py
        cp ${coreSrc}/src/engine.py $out/payload/engine.py
        cp ${../LICENSE} $out/payload/LICENSE
        cp ${
          pkgs.writeText "application.json" (
            builtins.toJSON {
              inherit program;
              hardware = if hardware == null then null else { preload = [ ]; } // hardware;
              nixBin = "${pkgs.nix}/bin";
              registerRoot = "${registerRoot}/bin/impurifier-register-root";
            }
          )
        } $out/payload/application.json
        ln -s ${pkg} $out/payload/nix-root
        ln -s ${sdk} $out/payload/sdk-root
        printf '#!${pkgs.python3}/bin/python3\nimport runpy\nfrom pathlib import Path\nrunpy.run_path(str(Path(__file__).resolve().parent.parent / "launch.py"), run_name="__main__")\n' > $out/payload/bin/${program}
        chmod 755 $out/payload/bin/${program}
        ${lib.optionalString offline ''
          cp -r ${core.offlineCache pkg} $out/payload/cache
          cp -r ${core.offlineCache sdk} $out/payload/sdk-cache
        ''}
        cat > $out/package.scm <<'SCM'
        (use-modules (guix packages) (guix gexp)
          (guix build-system trivial) (gnu packages guile) ((guix licenses) #:prefix license:))
        (package
          (name ${builtins.toJSON pkg.pname})
          (version ${builtins.toJSON pkg.version})
          (source (local-file (string-append (dirname (current-filename)) "/payload") #:recursive? #t))
          (build-system trivial-build-system)
          (arguments (list
          #:guile guile-3.0
            #:modules '((guix build utils))
            #:builder '(begin
              (use-modules (guix build utils))
              (copy-recursively (assoc-ref %build-inputs "source") (assoc-ref %outputs "out")))))
          (synopsis "Nix application in a native Guix package")
          (description "Guix owns this launcher and its immutable deployment roots; Nix owns the application closure.")
          (home-page "https://github.com/nix-impurifiers/guix-impurifier")
          (license license:expat))
        SCM
      '';
in
{
  inherit package sdk makePackage;
  tools = {
    package = pkgs.guix;
    inherit registerRoot;
  };
  makeNetPackage = args: makePackage (args // { offline = false; });
  makeOfflinePackage = args: makePackage (args // { offline = true; });
}
