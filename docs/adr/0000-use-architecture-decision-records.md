# Use Architecture Decision Records at Repository Root

**Status**: Accepted
**Date**: 2026-04-28
**Deciders**: Phillip Green II

## Context

Across the Nix configuration repositories (phillipgreenii-nix-personal,
phillipg-nix-ziprecruiter, phillipgreenii-nix-support-apps,
phillipgreenii-nix-overlay), architectural decisions accumulate over time —
technology choices, structural patterns, cross-cutting conventions — but live
only in commit history and tribal knowledge. As AI agents increasingly drive
development in these repos, the problem intensifies: agents lose conversation
context across sessions and cannot recover decision rationale from code alone.

We need a lightweight, discoverable way to capture architectural decisions that:

- Lives alongside code in version control
- Is accessible to both humans and AI agents
- Supports cross-repository references (decisions in one repo often affect others)
- Uses a consistent naming scheme for chronological traceability

## Decision

We adopt **Architecture Decision Records (ADRs)** stored in `docs/adr/` at each
repository root, using a `NNNN-{short-title}.md` naming scheme with zero-padded
sequential numbering.

### Directory Structure

```
<repo-root>/
└── docs/
    └── adr/
        ├── index.md
        ├── 0000-use-architecture-decision-records.md
        ├── 0001-next-decision.md
        └── draft-upcoming-decision.md
```

### Naming Conventions

- **Accepted ADRs**: `NNNN-{short-title}.md` — sequentially numbered per repo
- **Draft ADRs**: `draft-{short-title}.md` — unnumbered until accepted
- **NNNN** is a zero-padded 4-digit number; each repository maintains its own independent sequence

### Cross-Repository References

When a decision in one repo relates to a decision in another, the "Related Decisions" section uses the format:

    See also: <repo-name> docs/adr/NNNN-short-title.md

## Consequences

### Positive

- **Single discoverable location** per repo — `docs/adr/` is predictable and easy to find
- **Version-controlled alongside code** — decisions traceable in git history, reviewed in PRs
- **Chronological traceability** — sequential numbering reveals decision order and evolution
- **Cross-repo coherence** — explicit reference format connects related decisions across repos
- **Agent-friendly** — AI agents can read `docs/adr/` at session start to recover architectural context
- **Lightweight** — plain markdown, no special tooling required

### Negative

- **Numbering differs across repos** — no global sequence; cross-repo references must include the repo name
- **Write overhead** — creating an ADR takes effort, especially for retroactive decisions

### Neutral

- ADRs capture the "why" and "what", not detailed implementation
- Old ADRs remain in the repo even when deprecated or superseded, serving as historical record

## Alternatives Considered

### Wiki or External Documentation

**Rejected**: Not version-controlled alongside code. Another tool to maintain. Less discoverable for AI agents.

### Inline Code Comments

**Rejected**: Not discoverable without knowing where to look. Cannot capture cross-cutting context. Poor fit for decisions that span multiple files.

## Related Decisions

See also: phillipgreenii-nix-personal docs/adr/0000-use-architecture-decision-records.md
See also: phillipg-nix-ziprecruiter docs/adr/0000-use-architecture-decision-records.md
See also: phillipgreenii-nix-support-apps docs/adr/0000-use-architecture-decision-records.md
