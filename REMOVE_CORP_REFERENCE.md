# REMOVE_CORP_REFERENCE.md

## What this file is

This repository contains references to a current/former employer (ZipRecruiter, abbreviated
`ZR`) — principally an Eclipse plugin whose Java package namespace is claimed for the employer
and which exists to drive the employer's Gradle monorepo. This file tracks every such reference
so they can be removed as a unit.

**This file is itself temporary.** It is committed so the work is visible and resumable across
sessions, and the LAST item on the checklist below is to delete it. It MUST NOT outlive the
cleanup.

**Scope:** this repository only. Sibling trackers exist in `nix-agent-support`, `nix-personal`,
`nix-repo-base`, and `bb`. `homelab` and `ha-addon-esphome-mcp` are clean and have no tracker.

**Severity:** the lightest of the four contaminated repos — a single `ziprecruiter` occurrence
and 21 surviving `zr` identifiers, concentrated in one package. But see the note below: the
references here disclose the SHAPE of the employer's build (133 Gradle projects), and the repo
is already public.

## Provenance

Findings assembled 2026-08-12/13 from three independent read-only sweeps: current content at
every ref tip (incl. untracked and gitignored files), full reachable commit history
(`git log --all` pickaxe + diff-regex), and every object in the store regardless of
reachability (`git cat-file --batch-all-objects`), plus reflogs, notes, and `rr-cache`.

Counts are occurrences in the working tree, verified 2026-08-13, and are re-derivable. Re-run
the commands before claiming an item done; do not trust the recorded number.

```bash
rg -i -o 'ziprecruiter' . | wc -l   # expect 1 -> must reach 0
rg -i -o 'starterview'  . | wc -l   # expect 0 (clean)
rg -i -o -e '\bzr\b' -e '\bzr[-_./][a-z0-9-]+' . | wc -l   # expect ~21 -> must reach 0
```

---

## Findings

### A. Employer Java package namespace, shipped as source

The `zr.` namespace is claimed for the employer and appears in package declarations, bundle
metadata, and the directory tree itself:

| Location                                                                                  | Content                                                        |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `packages/eclipse-gradleimport-plugin/src/zr/eclipse/gradleimport/GradleImportApp.java:1` | `package zr.eclipse.gradleimport;`                             |
| `packages/eclipse-gradleimport-plugin/src/zr/`                                            | **directory name**                                             |
| `packages/eclipse-gradleimport-plugin/META-INF/MANIFEST.MF:3`                             | `Bundle-Name: ZR Gradle Headless Import`                       |
| `packages/eclipse-gradleimport-plugin/META-INF/MANIFEST.MF:4`                             | `Bundle-SymbolicName: zr.eclipse.gradleimport;singleton:=true` |
| `packages/eclipse-gradleimport-plugin/plugin.xml:5`                                       | `<run class="zr.eclipse.gradleimport.GradleImportApp"/>`       |
| `packages/eclipse-gradleimport-plugin/default.nix`                                        | 8 occurrences                                                  |
| `packages/eclipse-with-gradleimport/default.nix`                                          | 7 occurrences                                                  |
| `eclipse-dropins/zr*`                                                                     | 3 occurrences                                                  |

- [ ] **A1** — Rename the Java package to a neutral namespace (e.g. `dev.phillipgreenii.` or
      `local.eclipse.gradleimport`). This touches the package declaration, the directory path,
      `Bundle-SymbolicName`, `plugin.xml`, and both `default.nix` files together — a partial
      rename will not build.
- [ ] **A2** — Rename `Bundle-Name: ZR Gradle Headless Import`.
- [ ] **A3** — Rename the `eclipse-dropins/zr*` entries.

### B. Private sibling repo name in `flake.nix`

`flake.nix:13` — the sole `ziprecruiter` occurrence in the repo:

```
# consumer (agent-support, support-apps, ziprecruiter) follows the same pin.
```

- [ ] **B1** — Remove the employer name from this comment.

### C. Commit messages that describe the employer's build

Commit `92b5c1e` (2026-07-21) states verbatim that the import _"registers the full ZR Gradle
composite (133 projects, exit 0)"_ and _"Replaces the eclipse-java homebrew cask consumed by
phillipg-nix-ziprecruiter"_.

This discloses the employer's build topology and its scale. It is in the commit MESSAGE, so it
is not fixable by editing files.

- [ ] **C1** — Rewrite this commit message in the §E history rewrite.

### D. Filename / path references

- [ ] **D1** — `packages/eclipse-gradleimport-plugin/src/zr/` (see §A1)
- [ ] **D2** — `docs/adr/0013-update-sequence-np-then-sa-then-zr-via-flakeprojects-order.md`

Renaming an ADR changes its stable id. If ADR ids are load-bearing here, supersede rather than
rename, and ensure the superseding document carries no reference.

### E. Findings NOT fixable by editing files

These survive any content edit and MUST be handled explicitly.

| Item                    | Detail                                                                                                                                                                                                                                                   |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Commit authorship**   | **219 of 331 commits (66%)** are authored, and 204 committed, as `phillipg@ziprecruiter.com`. Also the unusual author name `nix_overlay/refinery <phillipg@ziprecruiter.com>` (1 commit). Baked into commit objects — only a history rewrite changes it. |
| **Commit messages**     | §C above.                                                                                                                                                                                                                                                |
| **Unreachable objects** | None carrying `ziprecruiter` — this repo's 160 unreachable objects are clean. It is the only contaminated repo where that is true.                                                                                                                       |

- [ ] **E1** — Rewrite history (`git filter-repo`) to purge the §B comment and the §C commit
      message.
- [ ] **E2** — Rewrite commit authorship to the personal identity in the same pass.
- [ ] **E3** — After rewrite, run `git reflog expire --expire=now --all` followed by
      `git gc --prune=now --aggressive`, then re-run the §Provenance sweeps to confirm 0
      across ALL objects.
- [ ] **E4** — Force-push, and confirm the remote no longer serves the old objects.

### F. Regression guard

A prior scrub in the sibling repos (2026-05-07) was partial and regressed within weeks. Do not
assume a one-off pass holds.

- [ ] **F1** — Add a CI guard (a test that fails on the forbidden strings) covering the whole
      repo. `nix-repo-base/modules/jira/pkg/pjira/guardrails_test.go` is a working precedent,
      but it covers ONE module only — this guard MUST cover the whole repo.

---

## Final item

- [ ] **Z1** — **DELETE THIS FILE.** It names the employer and describes the employer's build
      topology — it is itself a corporate reference and MUST NOT survive the cleanup. Removing
      it is the last step, and it MUST also be purged from history in the §E rewrite (or added
      after the rewrite and removed in a final ordinary commit).

## ⚠️ THIS REPOSITORY IS ALREADY PUBLIC

Verified 2026-08-13 against the GitHub API: `github.com/phillipgreenii/nix-overlay` has
`visibility: public`, last pushed 2026-08-12. **Everything above is world-readable right now.**

`homelab/nix/flake.nix:136` already consumes this repo as `github:phillipgreenii/nix-overlay`
— i.e. over the public fetcher — which independently confirms the public status.

### A history rewrite does NOT undo publication

Force-pushing a rewritten history removes the objects from `main`, but MUST NOT be treated as
un-publishing. GitHub continues to serve unreachable objects by SHA until Support runs garbage
collection; forks, clones, mirrors, code-search caches, and scrapers can all retain the old
content.

- [ ] **P1** — Consider making the repository private IMMEDIATELY as a containment step,
      before the cleanup rather than after. This is reversible; the exposure is not. **But
      note:** `homelab` consumes this repo via `github:`, which hits the unauthenticated GitHub
      API and will 404 on a private repo — making it private BREAKS the homelab flake until
      that input is switched to `git+ssh`. Sequence the two together.
- [ ] **P2** — After the §E rewrite and force-push, ask GitHub Support to garbage-collect
      unreachable objects, and check for forks.

## Once this list is complete

Once every item above is done and the verification sweeps return zero across all objects — not
just `main` — **this repository is safe to be public**, which it already is. If **P1** is taken
as containment, completing this list is what allows it to go public again.
