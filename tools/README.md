# tools — maintenance automation

Automation for MAINT-01 (upstream tracking + rebase bot) and MAINT-02
(AI fix-loop rules with explicit human gates, "call a human"). Policy
source: STRATEGY §8 — the automatable ~70% is machine work; stable
signing, key management and upstream social contact are never automated.

## Upstream tracking (MAINT-01)

- **`nvchecker.toml`** — 15 calibrated upstream entries (04-RESEARCH Q2):
  the vendored chain (waydroid/libglibutil/libgbinder/python-gbinder),
  upstream tags/releases, ALARM aarch64, danctnix releases,
  kupferbootstrap, phosh pkgver. Baseline: `nvchecker/oldver.txt`.
- **`nvchecker/alarm-pacman.conf`** — TUNA archlinuxarm db-sync config
  (note the `$arch/$repo` mirror layout); `nvchecker/expected-deps.txt`
  is the weekly drop/rename baseline.

One command (the docker battery; network required):

```sh
docker run --rm -v "$PWD":/work -w /work \
  -e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY -e GITHUB_TOKEN \
  archlinux:base bash tools/maintenance/upstream-check.sh
```

Artifacts land in `test/results/upstream/<ts>/` (`latest` symlink):
`check.jsonl` (per-source nvchecker results), `nvcmp.json` (drift), and
`drift-report.md` (old→new + Q2 action class per entry). Add `--check`
for a container-side environment self-check. `GITHUB_TOKEN` is optional
(runs anonymously at 60/h safely); when set it is written to a runtime
keyfile that is deleted on exit and never committed.

## Rebase bot (MAINT-01)

Consumes the check artifacts and takes the Q2 actions:

```sh
docker run --rm -v "$PWD":/work -w /work \
  archlinux:base bash tools/maintenance/rebase-bot.sh \
    --results-dir test/results/upstream/latest --weekly
```

- vendored-chain drift → **PR-ready artifacts** under
  `test/results/upstream/latest/pr/`: local branch `re-vendor/<pkg>-<ver>`
  + `git format-patch` bundle + PR body + clean-room build log
  (mechanical pkgver/sums/DIVERGENCE.md base-row edits; the current
  checkout is never touched; merge stays a HUMAN gate, STRATEGY §8);
- kupferbootstrap drift → a **rebase-plan** artifact (tag diff + steps);
- all other drift → **issue text** under `issue/` with the locez dedup
  semantics (`--existing-issues <file-of-titles>` switches matches to
  update-not-create);
- `--weekly` adds the drop/rename check (expected-deps vs upstream
  package pools → "meta 依赖断链" issue text; NEVER an auto-fork);
- `--take` / `--take-only` promote the taken state to the oldver.txt
  baseline after CONFIRMED processing only.

GitHub delivery (issues, PRs, baseline commit-back) is CI-deferred until
the repository has a remote; `.github/workflows/upstream.yml` runs this
exact battery daily (03:43 UTC) with the weekly face on Mondays and
uploads the artifacts.

## AI automation boundary (MAINT-02)

- **`ai-rules/call-a-human.yaml`** — machine-readable human gates
  (stable_signing / key_ops / direction_change → block; overlay_size /
  upstream_break → open_issue; device_ops → require_human). Semantics
  source: STRATEGY §8. Any agent doing mechanical fixes reads this file
  FIRST and stops at `block` gates.
- **`checks/validate-call-a-human.sh`** — schema + six-gate validator
  (positive/negative two-way; `--file` accepts a fixture).
- **`checks/assert-gate-boundary.sh`** — static scan that no workflow
  touches a `block` gate (token list: `checks/block-gate-tokens.txt`;
  `--workflows-dir` accepts a dir or a single file for negative tests).

```sh
bash tools/checks/validate-call-a-human.sh
bash tools/checks/assert-gate-boundary.sh
```
