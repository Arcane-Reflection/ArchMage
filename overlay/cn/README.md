# overlay/cn — CN factory-default meta packages

Pacman repo group `cn`: one package per directory (danctnix convention),
built by `.github/workflows/packages.yml` on arm64 runners into the signed
`staging-repo` artifact (`cn.db.tar.zst` + `.sig` + `staging-key.asc`).

Overlay-only rule applies (STRATEGY §4): packages here ship configuration
and depend on upstream packages; upstream PKGBUILDs are never forked.

Populated starting in Phase 1 (plan 01-01): mirror, net
(NTP/DNS/connectivity), locale, fonts meta packages and the
`archmage-cn` umbrella package.
