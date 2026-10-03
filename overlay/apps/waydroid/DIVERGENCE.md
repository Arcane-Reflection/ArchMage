# DIVERGENCE — vendored waydroid (overlay/apps/waydroid)

Vendor provenance ledger for the self-hosted waydroid package and the
gbinder dependency chain under `overlay/apps/` (03-02, threat T-03-30:
every vendored PKGBUILD pins its upstream base commit and lists its
deltas here — nothing else may drift silently).

## Vendor base — waydroid

| Field | Value |
| --- | --- |
| Upstream source | `aur://waydroid` (https://aur.archlinux.org/waydroid.git) |
| Base commit | `4b1f3d9` — "pkgctl license setup", 2025-10-30 |
| Base pkgver-pkgrel | `1.5.4-1` (upstream source pinned to waydroid tag 1.5.4, commit 661934e) |
| Vendored | 2026-10-02 (clone + re-check at execution time) |
| Maintainer (upstream) | Danct12 (danctnix) |

### Execution-time Releases re-check (2026-10-02)

- waydroid upstream latest release: **1.6.3** (2026-05-28 — adds initial
  Android 16 image support). The AUR base (1.5.4-1) lags upstream.
- Arch official `[extra]` at execution time carries **waydroid 1.6.3-1
  (`arch = any`)** plus the full gbinder chain (`libglibutil 1.0.82-1`,
  `libgbinder 1.1.52-1`, `python-gbinder 1.3.1-1`) — **x86_64 only**.
- Consequence (honest resolution matrix):
  - **x86_64** (QEMU dev image): `pacstrap waydroid` resolves the higher
    pkgver from `[extra]` (1.6.3-1) — the official build wins, and the
    official gbinder chain resolves from `[extra]` too. The vendored
    copies are NOT what the x86_64 image installs.
  - On **aarch64** (OP6 line): packages.yml builds this overlay on arm64
    runners; at plan-check time the gbinder chain had no aarch64 coverage
    anywhere (the self-hosted chain's original reason). At execution the
    gap itself has closed — ALARM's aarch64 `[extra]` now carries the
    whole chain (measured, see below) — so the staged copies are the
    fallback/insurance line, still buildable and CI auto-picked.

### Deltas vs base (waydroid)

1. The vendor comment header at the top of the PKGBUILD (this ledger's
   pointer). **No packaging/build delta** — body byte-identical to
   `4b1f3d9`.

### pkgname stays `waydroid`

Renaming (e.g. `archmage-waydroid`) would break `depends=` resolution
for consumers and fights pacman's provider matching; the factory
config that IS ours lives in the separate `archmage-waydroid-config`
package (overlay-only boundary: the vendored upstream package keeps
minimal divergence, ArchMage policy rides on top).

### arch coverage

`arch=('any')` upstream — aarch64 covered without modification. The
plan's anticipated minimal delta ("add aarch64 when upstream is
x86_64-only") was pre-satisfied by the AUR base; nothing to change.

### Follow-up TODOs

- Phase 4: nvchecker upstream tracking (`aur://waydroid` + waydroid
  GitHub releases) — until it exists, re-vendor by re-checking Releases
  and updating this ledger.
- The 1.5.4 → 1.6.x bump should be driven by the OP6 line's actual
  Android image needs (1.6.x adds Android 16 image support); not done in
  03-02 because the execution-time x86_64 smoke resolves 1.6.3-1 from
  `[extra]` regardless, and the aarch64 build must stay the AUR's
  maintained base until a re-vendor pass.

## Vendor base — gbinder chain (libglibutil / libgbinder / python-gbinder)

Gap set measured at execution time (2026-10-02, per plan: measure, don't
pre-judge — `pacman -Spq` on x86_64, ALARM aarch64 extra.db queried by
download + bsdtar):

- On **x86_64**: `pacman -Spq python-gbinder` resolves the whole chain
  from official `[extra]` — **no gap on x86_64**.
- On **aarch64 (ALARM extra.db measured 2026-10-02)**: ALARM has synced
  the chain — `libglibutil 1.0.82-1`, `libgbinder 1.1.52-1`,
  `python-gbinder 1.3.1-1` AND `waydroid 1.6.3-1` are all present in
  aarch64 `[extra]`. **The plan-check premise ("official extra carries
  the chain x86_64-only; nothing for aarch64") has narrowed further
  since 2026-09-27: at execution time there is NO hard gap left.**
- Consequence: the self-hosted copies are currently the *insurance*
  line, not the only provider — on both x86_64 and aarch64 pacman
  resolves the higher pkgver (1.6.3-1 / 1.3.1-1 …) from the official
  repos. They stay vendored per plan because the history that motivated
  them is real (danctnix dropped packaging) and can repeat: if Arch or
  ALARM drops or lags the chain again, the staging repo keeps waydroid
  resolvable without a scramble. 03-02 keeps them buildable, aarch64-
  capable and CI auto-picked (`overlay/*/*` glob); future re-vendor
  passes follow the ledger above.

| Package | Upstream source | Base commit | Base pkgver | Deltas |
| --- | --- | --- | --- | --- |
| libglibutil | `aur://libglibutil` | `9a62791` ("pkgctl license setup", 2025-10-30) | 1.0.80-1 | vendor comment header only |
| libgbinder | `aur://libgbinder` | `ccf6068` ("upgrade to 1.1.43", 2025-10-30) | 1.1.43-1 | vendor comment header only |
| python-gbinder | `aur://python-gbinder` | `7e0697c` ("pkgctl license setup", 2025-10-30) | 1.1.2-4 (+ `pr12.patch` from the same AUR commit) | vendor comment header only |

All three AUR PKGBUILDs already carry `aarch64` in `arch` (Danct12 keeps
the multiarch variant in AUR) — again pre-satisfied, nothing to change.
`python-gbinder`'s `pr12.patch` (distutils → setuptools migration,
required on python ≥ 3.12) is vendored verbatim from the same AUR
commit; it is part of the base, not a delta.

Version-lag note (same shape as waydroid): official `[extra]` carries
newer versions (libgbinder 1.1.52 etc.), x86_64-only. On x86_64 the
image resolves `[extra]`'s higher pkgvers; the vendored 1.1.43/1.0.80/
1.1.2 chain serves aarch64. Compatibility holds: python-gbinder 1.1.2
satisfies `libgbinder` (unversioned) and the built libgbinder 1.1.43
satisfies its own soname dep; `waydroid 1.5.4` depends on an unversioned
`python-gbinder`.

## OTA / offline image policy (execution-time facts, waydroid 1.5.4 source-verified)

- Default channels: `https://ota.waydro.id/system` / `/vendor`;
  init fetches `{channel}/{rom_type}/waydroid_{arch}/{system_type}.json`
  (defaults: rom_type=lineage, system_type=vanilla), downloads the zip,
  verifies its sha256 against the JSON's `id`, extracts to the images
  path (tools/actions/initializer.py + tools/helpers/images.py @ 1.5.4).
- Offline override that waydroid natively honors: `/etc/waydroid-extra/
  images/` (or `/usr/share/waydroid-extra/images/`) containing
  `system.img` + `vendor.img` — `waydroid init` short-circuits the OTA
  entirely (`system_ota = None`, updater disabled via
  `waydroid.updater.disabled=true`). This is the documented preinstalled
  path; `waydroid init -c/-v` is the built-in mirror override.
- The factory init script (`archmage-waydroid-init`, archmage-waydroid-config
  package) supports both: `WAYDROID_IMAGE_DIR/--image-dir` seeds the
  preinstalled path; `ARCHMAGE_WAYDROID_MIRROR/--mirror` feeds
  `waydroid init -c/-v`. The verify harness (test/waydroid/waydroid-verify.sh)
  mirrors the same semantics for the QEMU smoke (research A5: OTA
  reachability from CN networks is not assumed).
