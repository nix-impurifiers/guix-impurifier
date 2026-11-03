# guix-impurifier

Emit real Guix package definitions that install Nix-backed application launchers.
Guix owns the package files, profiles and generations; Nix owns the application
closure. Original code is MIT licensed. Guix and its bootstrap distribution
retain their GPL and component notices; they are dependencies, not relicensed
project code.

```nix
let
  impurifier = inputs.guix-impurifier.lib.guix-impurifier { inherit pkgs; };
in impurifier.makeOfflinePackage { pkg = pkgs.hello; }
```

Copy the output directory to the Guix host, then use native Guix:

```
guix package --install-from-file=./package.scm
```

`makeNetPackage` omits the offline cache; `makeOfflinePackage` includes the
application and tool caches. `makePackage` accepts `offline` and `program`.
The generated package uses native `trivial-build-system` with Guile 3.0 and
copies its source inside Guix's build sandbox. It requires no Nix invocation
at Guix build time. Preserve the adjacent `payload/` directory when moving
the package definition.

The host requires a working Nix daemon and this project's helper. For an
unsigned offline cache, prepare the installed Guix store package explicitly:

```
sudo guix-impurifier prepare --owner "$USER" /gnu/store/HASH-NAME-VERSION
```

Preparation verifies that Guix recognizes the store object, imports store data
without executing package code, then registers immutable deployment symlinks
as the owner. A normal user can prepare with trusted substituters. The host
Nix daemon continues to enforce its unsigned-import policy. This helper is
not yet an installer; native provisioning of Nix remains a deferred goal.

Launchers use a pinned Python/Nix tool closure. The matching helper supplies
that closure; offline artifacts also carry its cache. Native Nix API root
registration leaves the Guix store unchanged. Both application and tool roots
belong to the installed Guix store object. Removing a package from the current
profile does not release old generations: use native Guix generation deletion
and garbage collection, then Nix garbage collection, to release them.

The native VM fixture installs the official Guix 1.5.0 binary distribution,
including its original store database, and uses its matching daemon/client.
Guix's build sandbox remains enabled. Offline profile tests use native
`--bootstrap` profile mode and explicitly select the distribution's real
Guile 3.0 compiler through `%guile-for-build`; this omits optional profile hooks
whose separate build dependencies are absent from the binary bootstrap.
Full default-profile hooks, Guix System/Home services, signed remote channels
and native Nix provisioning need separate coverage.

The VM also checks rejected untrusted offline preparation, unchanged package
checksums, upgrades and rollback, retention of both generations across Nix GC,
and release after native generation deletion plus Guix GC.

Optional `hardware` uses the shared explicit host-library/program mapping.
Each launch captures selected host ELF libraries into an immutable Nix store
snapshot. Snapshots stay rooted in the user's state directory; after native
Guix GC removes the owning package, run `guix-impurifier prune` as the owner.
The VM replaces a real shared library and verifies that the next launch sees
its new version, then tests removal and pruning. GPU/kernel ABI compatibility
and automatic cleanup after arbitrary Guix transactions are not claimed.

## Prepared native packages and bundled clients

`makeNativePackage { name; version; payload; license ? null; }` emits a native
Guix package definition and a complete prepared prefix tree. Its trivial native
builder copies those files into the Guix output without adding a Nix SDK,
launcher or activation. The producer supplies files that already work in their
Guix output prefix; this does not relocate binaries. Optional `license` names a
Guix license identifier such as `expat`; omitted license metadata is `#f`.
Guix's own store, daemon, builder and profile semantics still apply.

The VM builds and installs emitted native definitions, executes static payloads,
changes versions, rolls back and replaces the profile manifest to remove the
application. An installed executable also runs in an isolated root without
`/nix`. The manager fixture uses the official Guix bootstrap and NixOS host
tools; it does not claim a complete Guix System boot without Nix.

Nix-backed constructors accept `bundledNixStore` (a static ELF client) and
`bundledNixNotices` (upstream notice files). They carry a private client and omit
the SDK CLI. Launch selects a compatible external client before the bundle,
before registering immutable roots or capturing hardware; explicit
`IMPURIFIER_NIX_STORE` disables fallback. Trusted initial preparation uses host
tools and never executes the Guix-output-owned client as root. Existing Nix
store/daemon infrastructure and initial SDK preparation remain necessary. The
bundled VM repeats the profile, rollback, hardware and GC lifecycle with an
incompatible external candidate.
