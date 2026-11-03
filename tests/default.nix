# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
  tools,
  bundled ? false,
}:
let
  app = pkgs.writeShellScriptBin "guix-app" "echo guix-nix-one" // {
    pname = "guix-app";
    version = "1";
  };
  staticNix = import (coreSrc + "/tests/static-nix.nix") { inherit pkgs; };
  bundleArgs = pkgs.lib.optionalAttrs bundled {
    bundledNixStore = "${staticNix}/bin/nix-store";
    bundledNixNotices = [ "${pkgs.nix.src}/COPYING" ];
  };
  builder = impurifier // {
    makeNetPackage = args: impurifier.makeNetPackage (args // bundleArgs);
    makeOfflinePackage = args: impurifier.makeOfflinePackage (args // bundleArgs);
  };
  native =
    version:
    impurifier.makeNativePackage {
      name = "native-proof";
      inherit version;
      license = "expat";
      payload =
        pkgs.runCommand "native-guix-${version}" { nativeBuildInputs = [ pkgs.pkgsStatic.stdenv.cc ]; }
          ''
            mkdir -p $out/bin
            echo '#include <stdio.h>' > proof.c
            echo 'int main(void) { puts("native-guix-${version}"); return 0; }' >> proof.c
            $CC -static proof.c -o $out/bin/native-proof
          '';
    };
  nativeManifest =
    version:
    pkgs.writeText "native-guix-manifest-${version}.scm" ''
      (use-modules (guix profiles) (guix store) (guix packages) (gnu packages guile))
      (with-store store (%guile-for-build (package-derivation store guile-3.0 #:graft? #f)))
      (packages->manifest (list (load "/home/consumer/native${version}/package.scm")))
    '';
  emptyManifest = pkgs.writeText "native-guix-empty.scm" ''
    (use-modules (guix profiles) (guix store) (guix packages) (gnu packages guile))
    (with-store store (%guile-for-build (package-derivation store guile-3.0 #:graft? #f)))
    (use-modules (guix gexp))
    (manifest (list (manifest-entry
      (name "empty-native-marker") (version "1")
      (item (local-file "/home/consumer/empty-tree" #:recursive? #t)))))
  '';
  emitted = builder.makeOfflinePackage { pkg = app; };
  packageManifest = pkgs.writeText "guix-application-manifest.scm" ''
    (use-modules (guix profiles) (guix store) (guix packages) (gnu packages guile))
    (with-store store (%guile-for-build (package-derivation store guile-3.0 #:graft? #f)))
    (packages->manifest (list (load "/home/consumer/emitted/package.scm")))
  '';
  app2 = pkgs.writeShellScriptBin "guix-app" "echo guix-nix-two" // {
    pname = "guix-app";
    version = "2";
  };
  emitted2 = builder.makeOfflinePackage { pkg = app2; };
  net = builder.makeNetPackage { pkg = app; };
  packageManifest2 = pkgs.writeText "guix-application-manifest-2.scm" ''
    (use-modules (guix profiles) (guix store) (guix packages) (gnu packages guile))
    (with-store store (%guile-for-build (package-derivation store guile-3.0 #:graft? #f)))
    (packages->manifest (list (load "/home/consumer/emitted2/package.scm")))
  '';
  fixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  hardware = builder.makeOfflinePackage {
    pkg = fixture.tool;
    inherit (fixture) hardware;
  };
  bootstrap = pkgs.fetchurl {
    url = "https://ftp.gnu.org/gnu/guix/guix-binary-1.5.0.x86_64-linux.tar.xz";
    hash = "sha256-qkECVInFBhVD6cSIc+qoKbkAstp11A+WSJE2IvX0eBc=";
  };
  manifest = pkgs.writeText "guix-native-manifest.scm" ''
    (use-modules (guix profiles) (guix gexp) (guix store) (guix packages) (guix derivations) (gnu packages guile))
    (with-store store
      (let ((guile (package-derivation store guile-3.0 #:graft? #f)))
        (format (current-error-port) "Native profile Guile: ~a~%" (derivation->output-path guile))
        (%guile-for-build guile)))
    (manifest (list (manifest-entry
      (name "native-marker") (version "1")
      (item (local-file "/home/consumer/payload" #:recursive? #t)))))
  '';
in
{
  native-vm = pkgs.testers.runNixOSTest {
    name = "guix-native-contract${pkgs.lib.optionalString bundled "-bundled"}";
    globalTimeout = 1200;
    requiredFeatures = {
      kvm = false;
      devnet = false;
    };
    nodes.machine = { lib, ... }: {
      virtualisation.qemu.package = lib.mkForce pkgs.qemu;
      virtualisation.qemu.forceAccel = false;
      virtualisation.memorySize = 3072;
      virtualisation.diskSize = 12288;
      services.guix.enable = true;
      services.guix.substituters.urls = [ ];
      systemd.services.guix-daemon.serviceConfig.ExecStart =
        lib.mkForce "/gnu/store/ganla421f3g1p9rh3r68zj9djc9b807m-guix-1.5.0/bin/guix-daemon --build-users-group=guixbuild";
      environment.systemPackages = [
        impurifier.package
        pkgs.guix
        pkgs.nix
      ];
      users.users.consumer.isNormalUser = true;
    };
    testScript = ''
      import shlex
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("systemctl stop guix-daemon.socket guix-daemon.service; systemctl reset-failed guix-daemon.service; mount -o remount,bind,rw /gnu/store; tar -xJf ${bootstrap} -C /; mount -o remount,bind,ro /gnu/store; systemctl start guix-daemon.socket guix-daemon.service")
      machine.wait_for_unit("guix-daemon.service")
      machine.succeed("cp -r ${hardware} /home/consumer/hardware; cp -r ${emitted2} /home/consumer/emitted2; cp -r ${net} /home/consumer/net; cp ${packageManifest2} /home/consumer/application2.scm; cp -r ${emitted} /home/consumer/emitted; cp ${packageManifest} /home/consumer/application.scm; chown -R consumer:users /home/consumer/emitted /home/consumer/application.scm")
      machine.succeed("mkdir -p /home/consumer/payload/bin; printf '#!/bin/sh\\necho native-guix\\n' > /home/consumer/payload/bin/native-marker; chmod 755 /home/consumer/payload/bin/native-marker; cp ${manifest} /home/consumer/manifest.scm; chown -R consumer:users /home/consumer/payload /home/consumer/manifest.scm")
      machine.succeed("mkdir -p /root/drivers /usr/lib; cp ${fixture.driver "1"}/usr/lib/libimpurifier-driver.so.1 /root/drivers/1.so; cp ${fixture.driver "2"}/usr/lib/libimpurifier-driver.so.1 /root/drivers/2.so")
      guix = "/var/guix/profiles/per-user/root/current-guix/bin/guix"
      def succeed(command):
          return machine.succeed("su - consumer -c " + shlex.quote(("PATH=/home/consumer/no-nix:$PATH " if ${
            if bundled then "True" else "False"
          } else "") + command))
      succeed(guix + " package --bootstrap --no-substitutes -p /home/consumer/profile -m /home/consumer/manifest.scm")
      assert succeed("/home/consumer/profile/bin/native-marker").strip() == "native-guix"
      succeed(guix + " package -p /home/consumer/profile --list-installed")
      machine.succeed("cp -r ${native "1"} /home/consumer/native1; cp -r ${native "2"} /home/consumer/native2; cp ${nativeManifest "1"} /home/consumer/native1.scm; cp ${nativeManifest "2"} /home/consumer/native2.scm; cp ${emptyManifest} /home/consumer/empty.scm; mkdir -p /home/consumer/empty-tree/share; echo empty > /home/consumer/empty-tree/share/empty")
      succeed(guix + " package --bootstrap --no-substitutes -p /home/consumer/native-profile -m /home/consumer/native1.scm")
      assert succeed("/home/consumer/native-profile/bin/native-proof").strip() == "native-guix-1"
      machine.succeed("mkdir -p /srv/native/bin; cp /home/consumer/native-profile/bin/native-proof /srv/native/bin/native-proof")
      assert machine.succeed("chroot /srv/native /bin/native-proof").strip() == "native-guix-1"
      machine.succeed("test ! -e /srv/native/nix; test ! -e /home/consumer/native-profile/launch.py")
      succeed(guix + " package --bootstrap --no-substitutes -p /home/consumer/native-profile -m /home/consumer/native2.scm")
      assert succeed("/home/consumer/native-profile/bin/native-proof").strip() == "native-guix-2"
      succeed(guix + " package -p /home/consumer/native-profile --roll-back")
      assert succeed("/home/consumer/native-profile/bin/native-proof").strip() == "native-guix-1"
      succeed(guix + " package --bootstrap --no-substitutes -p /home/consumer/native-profile -m /home/consumer/empty.scm")
      machine.succeed("test ! -e /home/consumer/native-profile/bin/native-proof")
      ${pkgs.lib.optionalString bundled ''
        machine.succeed("mkdir -p /home/consumer/no-nix; printf '#!${pkgs.runtimeShell}\\necho incompatible-client\\n' > /home/consumer/no-nix/nix-store; chmod 755 /home/consumer/no-nix/nix-store")
      ''}
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
      succeed(guix + " package --bootstrap --no-substitutes -p /home/consumer/app-profile -m /home/consumer/application.scm")
      implementation = succeed("readlink -f /home/consumer/app-profile/bin/guix-app").strip().rsplit('/bin/', 1)[0]
      checksum = machine.succeed("find " + implementation + " -type f -exec sha256sum {} + | sort")
      machine.fail("su - consumer -c 'guix-impurifier prepare " + implementation + "'")
      machine.succeed("guix-impurifier prepare --owner consumer " + implementation)
      machine.succeed("nix-store --gc")
      assert succeed("/home/consumer/app-profile/bin/guix-app").strip() == "guix-nix-one"
      assert machine.succeed("find " + implementation + " -type f -exec sha256sum {} + | sort") == checksum
      succeed(guix + " package --bootstrap --no-substitutes -p /home/consumer/app-profile -m /home/consumer/application2.scm")
      implementation2 = succeed("readlink -f /home/consumer/app-profile/bin/guix-app").strip().rsplit('/bin/', 1)[0]
      machine.fail("su - consumer -c /home/consumer/app-profile/bin/guix-app")
      machine.succeed("guix-impurifier prepare --owner consumer " + implementation2)
      assert succeed("/home/consumer/app-profile/bin/guix-app").strip() == "guix-nix-two"
      succeed(guix + " package -p /home/consumer/app-profile --roll-back")
      assert succeed("/home/consumer/app-profile/bin/guix-app").strip() == "guix-nix-one"
      succeed(guix + " package -p /home/consumer/app-profile --switch-generation=2")
      assert succeed("/home/consumer/app-profile/bin/guix-app").strip() == "guix-nix-two"
      machine.succeed("nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}; test -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      succeed(guix + " package -p /home/consumer/app-profile --delete-generations=1")
      machine.succeed(guix + " gc")
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}; test -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      succeed("rm /home/consumer/app-profile /home/consumer/app-profile-*-link")
      machine.succeed(guix + " gc")
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      succeed(guix + " build --no-substitutes -f /home/consumer/net/package.scm --root=/home/consumer/net-root")
      net_implementation = succeed("readlink -f /home/consumer/net-root").strip()
      machine.fail("su - consumer -c 'guix-impurifier prepare " + net_implementation + "'")
      succeed("rm /home/consumer/net-root")
      succeed(guix + " build --no-substitutes -f /home/consumer/hardware/package.scm --root=/home/consumer/hardware-root")
      hardware_implementation = succeed("readlink -f /home/consumer/hardware-root").strip()
      machine.succeed("guix-impurifier prepare --owner consumer " + hardware_implementation + "; cp /root/drivers/1.so /usr/lib/libimpurifier-driver.so.1")
      assert succeed("/home/consumer/hardware-root/bin/hardware-tool").strip() == "1"
      machine.succeed("cp /root/drivers/2.so /usr/lib/libimpurifier-driver.so.1")
      assert succeed("/home/consumer/hardware-root/bin/hardware-tool").strip() == "2"
      succeed("rm /home/consumer/hardware-root")
      machine.succeed(guix + " gc")
      succeed("guix-impurifier prune")
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString fixture.tool)}")
    '';
  };
}
