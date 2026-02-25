---
status: Accepted
date: 2026-02-25
category: Process
deciders: [peterkc]
tags: [contribution, upstream, rubric]
---

# ADR 4001: Issue Selection Rubric for Upstream Contributions

## Context

We're contributing to Kilo-Org/kilocode as an external contributor with architectural goals (AHP: ckd memory, bdx work, native skills). Without a repeatable framework, issue selection is ad-hoc — risking wasted effort on issues that are assigned, intentionally deprecated, or misaligned with our direction.

The kilocode repo has 651 open issues across bugs, features, CLI, backend, and frontend. We need to filter to the highest-value targets.

## Decision Drivers

- Limited contributor bandwidth — can't pursue everything
- Need credibility before proposing core changes (Phase 1 → 2 → 3)
- Provider-layer work directly builds knowledge for Phase 2 plugins
- Issues with open PRs or assignees waste effort

## Considered Options

### Option 1: Five-Dimension Scoring Rubric

Score each candidate on 5 dimensions (0-2 each, max 10). Threshold: >= 6 to pursue, >= 8 = high priority.

| Dimension | 0 | 1 | 2 |
|-----------|---|---|---|
| Demand | 0 reactions | 1-5 reactions | 10+ reactions |
| Scope | Unclear or deep core | Medium (2-3 files) | Small (1 file, mechanical) |
| Availability | Assigned or open PR | Stale PR or unowned | No PR, no assignee |
| Alignment | Unrelated to goals | Builds knowledge | Directly on contribution path |
| Signal | Team may not want | Neutral | `help-wanted` or team invitation |

- **Good, because** repeatable and documented — every issue gets a score
- **Good, because** alignment dimension prevents drift from architecture goals
- **Good, because** availability check prevents wasted effort on claimed work
- **Bad, because** scores are subjective — "scope: 1 vs 2" requires judgment

### Option 2: Reactions-Only Ranking

Sort by GitHub reactions, pick top N.

- **Good, because** simple and objective
- **Bad, because** ignores scope, availability, and alignment
- **Bad, because** high-reaction issues may be assigned or have PRs

### Option 3: Freeform Judgment

No rubric — pick what feels right per session.

- **Good, because** no overhead
- **Bad, because** non-repeatable, prone to selection bias
- **Bad, because** no audit trail for why issues were chosen or skipped

## Decision

**Chosen option**: Option 1 (Five-Dimension Scoring Rubric), because it balances rigor with practicality and ensures every decision is documented with a score.

## Consequences

### Positive

- Every issue in kc-934 (Phase 1) has a documented score
- Issues scoring < 6 are not pursued, preventing scope creep
- Alignment dimension keeps work on the architecture path

### Negative

- Scoring adds ~2 minutes per candidate evaluation
- Subjective dimensions (scope, alignment) may vary between sessions

### Neutral

- The rubric evolves — dimensions can be adjusted via ADR amendment

## Tracking

- Beads: `kc-934` (Phase 1 epic)
- Research: `.agents/research/kilo-cli-rebuild-analysis/contribution-strategy.md`

## Related

- Research: `contribution-strategy.md` — full strategy with scored roster
