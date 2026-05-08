# Symphony Epic Handling — Design

**Date:** 2026-05-08
**Status:** Draft (awaiting implementation plan)
**Author:** brainstormed with Claude (Opus 4.7)
**Repo touched:** symphony (Elixir reference implementation)
**Related issue context:** AnattaResearch/alpha #133 (epic that Symphony silently treated as a single issue, leaving sub-issues unhandled)

---

## 1. Problem

Symphony's GitHub adapter normalizes every issue into a flat `%Issue{}` struct with no concept of parent/child or peer dependencies (`elixir/lib/symphony_elixir/issue.ex:9-24`). When an epic / tracking issue is dispatched, the agent sees only `title`, `description`, `labels`, `url` — never the structured sub-issues — and the workflow prompt biases it toward "the smallest change that satisfies the issue" plus exactly one PR (`WORKFLOW.alpha.md:91, 97-100`). The result is a *silent partial completion*: the parent gets a PR and lands in `human-review`, but every sub-issue stays untouched.

The user's intent is for the agent to recognize epic-shaped work and execute it as a multi-issue project, with **agent judgment** driving sub-issue ordering (because GitHub has no native peer-dependency relation).

---

## 2. Goals

- Symphony detects GitHub epics automatically (no human gating needed for the common path).
- Sub-issues are dispatched as independent units of work, each producing its own branch, PR, and review cycle.
- An LLM — not Symphony — decides the dependency graph between sub-issues, because that requires semantic understanding of each sub-issue's body.
- The dependency decision is durably recorded on GitHub (auditable by humans) and machine-parseable by Symphony.
- Existing single-issue dispatch flow is unchanged.

## 3. Non-goals (deferred to a later iteration)

- Re-planning when the epic body or sub-issue list mutates after the initial plan was written.
- Recursively expanding nested epics (a sub-issue that is itself an epic).
- Parallel execution of independent children (`max_concurrent_agents > 1`). The graph machinery is in place; this is a config bump only.
- Linear-side epic semantics (Linear uses Project rather than parent-issue, requires a different design).
- Mutating the parent epic's body (we only comment on it, never edit its body).

---

## 4. Context — what already exists in Symphony

This design composes onto existing machinery rather than rewriting it.

| Capability | File | Status |
|---|---|---|
| Tracker-agnostic `%Issue{}` struct (incl. `blocked_by`) | `elixir/lib/symphony_elixir/issue.ex` | Already present |
| Orchestrator dependency gate (holds `Todo` issues whose blockers are non-terminal) | `elixir/lib/symphony_elixir/orchestrator.ex:614-629` | Already present, currently only fed by Linear |
| Linear adapter populates `blocked_by` from `inverseRelations` (type=`blocks`) | `elixir/lib/symphony_elixir/linear/client.ex:550-573` | Reference pattern |
| GitHub adapter populates `blocked_by` | `elixir/lib/symphony_elixir/github/client.ex:153-172` | **Always `[]`** — gap to fill |
| State↔label mapping for GitHub | `elixir/lib/symphony_elixir/github/state_mapping.ex` | Needs new `epic-tracking` entry |
| Workflow templating (Liquid/Solid) | `elixir/lib/symphony_elixir/prompt_builder.ex`, `WORKFLOW.alpha.md` | Needs second prompt slot for planner |
| Per-issue agent run | `elixir/lib/symphony_elixir/agent_runner.ex` | Reused unchanged for children; reused with different prompt for the planner |

---

## 5. High-level flow

```
                          ┌────────────────────────────────────────┐
                          │ polling cycle picks Todo issue #N       │
                          └────────────────┬───────────────────────┘
                                           │
                            GET /issues/{N}/sub_issues (new call)
                                           │
                  ┌────────────────────────┴──────────────────────┐
                  │ empty                                      non-empty
                  ▼                                                ▼
        existing single-issue flow              ┌──────────────────────────────────┐
        (unchanged)                              │ Has YAML plan in epic comments? │
                                                 └────────┬──────────────┬────────┘
                                                          │ no           │ yes
                                                          ▼              ▼
                                              run PLANNER agent     parse plan,
                                              (special prompt) →    populate blocked_by
                                              writes YAML comment   on each child,
                                              + applies labels       dispatch ready ones
                                                          │              │
                                                          └──────┬───────┘
                                                                 ▼
                                            children flow through normal Symphony
                                            cycle, one branch + one PR each, in
                                            blocked_by-respecting order

                                            reaper: when all children Done,
                                            close parent epic
```

---

## 6. Component-by-component design

### 6.1 Epic detection — `GitHub.Client`

Add `fetch_sub_issues/1`:

```elixir
@spec fetch_sub_issues(String.t()) :: {:ok, [issue_number :: integer()]} | {:error, term()}
```

Calls `GET /repos/{repo}/issues/{n}/sub_issues` (REST endpoint added by GitHub in 2024). Returns the list of child issue numbers.

Add `fetch_issue_comments/1`:

```elixir
@spec fetch_issue_comments(String.t()) :: {:ok, [%{id: integer(), body: String.t(), updated_at: DateTime.t()}]} | {:error, term()}
```

Calls `GET /repos/{repo}/issues/{n}/comments`. Used to find the YAML plan written by the planner agent.

Both functions should follow the existing pagination + error pattern (see `do_paginate/5`).

### 6.2 Plan format and parser — new module `GitHub.EpicPlan`

The planner agent posts exactly one comment on the parent epic with this block:

```yaml
<!-- symphony-plan:v1 -->
schema: 1
generated_at: 2026-05-08T12:34:56Z
sub_issues:
  - id: 134
    blocked_by: []
    rationale: "Defines DB schema; everything else needs it."
  - id: 135
    blocked_by: [134]
    rationale: "Migration depends on schema."
  - id: 136
    blocked_by: [134]
    rationale: "API endpoint depends on schema, but parallel with #135."
<!-- /symphony-plan -->
```

`GitHub.EpicPlan` exposes:

```elixir
@spec extract(comments :: [String.t()]) :: {:ok, plan_map :: %{...}} | {:error, :no_plan | {:invalid_yaml, term()} | {:schema_mismatch, term()}}
@spec blockers_for(plan_map, child_id :: integer()) :: [integer()]
```

Parsing rules:

- Find the comment(s) containing `<!-- symphony-plan:v1 -->` … `<!-- /symphony-plan -->`. If multiple, use the **most recent** (latest `updated_at`).
- The block content between the markers is parsed as YAML. Use a permissive YAML lib (e.g., `:yamerl` is already in deps; otherwise add `YamlElixir`).
- Validate: `schema == 1`; `sub_issues` is a list; each entry has integer `id`, list of integers `blocked_by`. Reject otherwise.
- The YAML can contain extra fields (`rationale`, future additions) — parser ignores unknown keys.

Field rationale:
- `schema`: future-proofing; if we change format, bump and write a migrator.
- `generated_at`: lets a future re-plan logic detect staleness.
- `rationale`: non-functional, but valuable for human auditors and for debugging when the planner makes a wrong call.

### 6.3 GitHub adapter integration — `GitHub.Adapter` + `GitHub.Client`

`fetch_candidate_issues/0` and `fetch_issues_by_states/1` need to populate `blocked_by` for any issue that is referenced by a parent epic's plan. The simplest implementation:

1. Fetch issues normally (one page request).
2. For each issue without a Symphony state label yet, check whether it appears in any parent epic's plan. If so, fill `blocked_by` from the plan.

Performance note: an N+M pattern (N issues, M epics) is fine for a small repo. For larger repos, cache plans in-process per polling cycle. Caching is a v1 requirement only if a single polling round would otherwise issue >20 GitHub requests; for AnattaResearch/alpha that's unlikely.

A child's `blocked_by` entries take the existing shape `[%{state: blocker_state}, ...]` consumed by `orchestrator.ex:614-629`. To construct these:

1. The polling round already has every open issue in memory (from `list /issues`). Build a `%{issue_number => state_name}` map once per round.
2. For each child whose plan declares `blocked_by: [134, ...]`, look each blocker number up in the map and emit `%{state: state_name}`. If a blocker is not in the map (e.g., it was closed and `state: "all"` happens to omit it), look it up via `fetch_issue_states_by_ids/1` as a fallback.

This avoids per-child round-trips in the common case.

### 6.4 Epic state mapping — `GitHub.StateMapping`

Add the new label↔state pair:

| Label | State name | In `active_states`? | In `terminal_states`? |
|---|---|---|---|
| `symphony:epic-tracking` | `Epic Tracking` (or similar) | **No** | **No** |

The state being neither active nor terminal means: orchestrator's polling won't redispatch it (good — planner already ran), but the parent isn't considered "done" until the reaper closes it.

`StateMapping.label_ops_for_state/2` must know that switching to `epic-tracking` removes `symphony:in-progress` and `symphony:todo`.

### 6.5 Planner prompt — `WORKFLOW.alpha.md` + `prompt_builder.ex`

Workflow YAML frontmatter gets a second prompt body slot. Today the file has one Liquid template after the frontmatter; the new shape:

```yaml
prompts:
  default: |
    You are working on AnattaResearch/alpha issue #{{ issue.identifier }}.
    ... (existing single-issue prompt body)
  epic_planner: |
    You are PLANNING (not implementing) AnattaResearch/alpha epic #{{ issue.identifier }}.
    Sub-issues: {{ epic.sub_issue_numbers | join: ', ' }}.

    Your job:
    1. For each sub-issue, run `gh issue view <n> --comments --repo AnattaResearch/alpha` and read it.
    2. Decide the dependency graph between sub-issues. Use semantic judgment — what defines a contract, what depends on a contract, what is parallelizable.
    3. Comment ONCE on the parent epic with this exact wrapped YAML block:

       <!-- symphony-plan:v1 -->
       schema: 1
       generated_at: <ISO 8601 UTC>
       sub_issues:
         - id: <number>
           blocked_by: [<number>, ...]
           rationale: "<one short sentence>"
         ...
       <!-- /symphony-plan -->

    4. For each sub-issue, run:
         gh issue edit <n> --repo AnattaResearch/alpha --add-label symphony:todo
    5. For the parent epic, replace the in-progress label with epic-tracking:
         gh issue edit {{ issue.identifier }} --repo AnattaResearch/alpha \
           --remove-label symphony:in-progress --add-label symphony:epic-tracking
    6. Stop. Do NOT open a PR. Do NOT modify any code in this run.
```

Backward compatibility: workflows that don't set `prompts:` continue to use the legacy single-template form (so existing tests / integrations don't break).

The `prompt_builder.ex` `build_prompt/2` learns a new keyword option `:variant` (`:default | :epic_planner`) and selects the right template. Solid context gets a new `epic` map when variant is `:epic_planner`:

```elixir
%{
  "issue" => issue_map,
  "epic" => %{
    "sub_issue_numbers" => [134, 135, 136]
  },
  "attempt" => attempt
}
```

### 6.6 Orchestrator changes

In the dispatch path, after fetching the issue and before running the agent:

1. If `issue.state == "Todo"` and the GitHub tracker reports non-empty sub-issues for this issue (cached on the `%Issue{}` as a transient field, e.g., `:meta`):
   - If a valid plan comment already exists → skip planner, treat parent as `epic-tracking` (apply label, return), do nothing else this cycle. Children will pick up via normal polling now that their `blocked_by` is populated.
   - If no plan comment → invoke a planner agent run with `variant: :epic_planner` and `max_turns: 4` (planner's work is bounded; tighter cap reduces wandering).

2. Add a "reaper" pass (one new function called from the polling tick):
   - Iterate issues in state `epic-tracking`.
   - For each, fetch sub-issues; if **every** sub-issue is in state `Done` specifically (not merely `Human Review`), call `update_issue_state(epic_id, "Done")`. Else leave alone.
   - Why `Done`-only: `Human Review` means the child PR is open but not merged; closing the parent at that point would be premature. `Done` requires the PR to have been merged (which is what flips the child's terminal label per the existing flow).

The reaper is intentionally simple — it runs every poll, is idempotent, and never opens a PR.

### 6.7 Failure handling

| Failure | Symphony action |
|---|---|
| Sub-issues API call fails | Log; treat as non-epic this cycle; retry next polling tick. |
| Planner agent exits with no plan written / invalid YAML | Move parent to `symphony:human-review` with a comment naming the failure. Children remain unlabeled (Symphony will not touch them). |
| Planner exceeds `max_turns` mid-write | Same as above — invalid plan ⇒ human-review on parent. |
| One child's implementation agent fails | Existing single-issue failure path applies (`symphony:human-review` on that child). Children that depend on it stay blocked indefinitely; this is expected behavior, surfaces clearly via Symphony dashboard. |
| Sub-issue is itself an epic | Out of scope. The child planner detection short-circuits if `epic-tracking` is encountered in `blocked_by` resolution; the nested epic is treated as a regular issue. Documented as v1 limitation. |
| Plan references a sub-issue number that doesn't exist | Planner is fallible. `EpicPlan.extract/1` validates that every `id` in the plan corresponds to a real sub-issue (using the sub-issues API list). If mismatch, treat as invalid plan ⇒ human-review on parent. |

### 6.8 Configuration surface

No new top-level config keys. The only operator-visible knobs are:

- `agent.max_turns` — used as the cap for both default and planner variants; planner gets `min(4, agent.max_turns)`.
- `tracker.active_states` — must NOT include `Epic Tracking`. Schema validation enforces.

---

## 7. Data flow & invariants

### Invariants

1. **Symphony never edits a child's body.** All metadata about dependencies lives in the parent's plan comment. (Avoids body-edit conflicts with humans.)
2. **The parent epic's state label is the single source of truth for "epic was already planned":** `symphony:epic-tracking` ⇔ plan exists ⇔ children labeled.
3. **`blocked_by` is computed at fetch time, not stored persistently in Symphony.** Symphony has no DB. The plan comment is the persistent state; everything else is derived.
4. **Children referenced by a plan inherit the active_states gate.** If a child has no Symphony label, it's not picked up. Planner is responsible for labeling each child `symphony:todo`. (If planner fails mid-loop, partially labeled children are still OK — orchestrator's blocker gate keeps them held until upstream is Done.)

### Data-flow trace (success path)

```
poll tick
  → fetch_candidate_issues
    → list /issues
    → for each issue:
      → fetch /issues/{n}/sub_issues
        → if non-empty:
          → fetch /issues/{n}/comments
            → EpicPlan.extract → :no_plan
              → emit plan_required event
            → emit no-op for non-epic
  → orchestrator.handle_dispatch
    → if plan_required:
      → spawn agent_run with variant=:epic_planner, max_turns=4
      → planner agent posts YAML, labels children, switches parent label
  → next poll tick
    → fetch_candidate_issues sees children with symphony:todo and blocked_by populated from plan
    → children with empty blocked_by are dispatched
    → as each child reaches Done, downstream blocked_by clears
  → reaper sees all children Done → closes parent
```

---

## 8. Testing strategy

### Unit tests

- `GitHub.EpicPlan` — extract/parse, schema mismatch rejection, multi-comment latest-wins, malformed YAML, non-existent IDs.
- `GitHub.Client.fetch_sub_issues/1` and `fetch_issue_comments/1` against a Bypass-stubbed GitHub.
- `GitHub.StateMapping` for the new `epic-tracking` ↔ label mapping.
- `prompt_builder.ex` variant selection.

### Integration tests (Memory tracker)

The `Tracker.Memory` adapter doesn't model sub-issues. To keep the integration suite tractable, **either**:
- Add minimal sub-issue support to `Tracker.Memory` (a `:sub_of` field on memory issues, and a corresponding `fetch_sub_issues` callback), OR
- Restrict epic integration tests to GitHub via Bypass.

Recommendation: extend `Tracker` behaviour with optional `c:fetch_sub_issues/1` callback (default `{:ok, []}`) and add minimal `Tracker.Memory` support; this keeps GitHub-specific HTTP out of orchestrator tests.

End-to-end scenarios to cover:
- Happy path: 3 sub-issues, partial dependency graph, all complete in topo order.
- No plan written by planner → parent goes to human-review.
- Plan references invalid IDs → parent goes to human-review.
- Mid-flight: child #135 fails → child #136 (depends on #135) stays blocked; child #134 (independent) continues.
- Re-poll after plan exists: planner is NOT re-run.
- Reaper closes parent after all children Done.

### Spec compliance

`Mix.Tasks.SpecsCheck` (`elixir/lib/mix/tasks/specs.check.ex`) walks SPEC.md against runtime invariants. SPEC.md must be updated to describe epic handling; specs.check must pass.

---

## 9. Documentation updates

- `SPEC.md` — new section "Epic handling (GitHub)" documenting the data model, plan format, state machine.
- `WORKFLOW.alpha.md` — example epic_planner prompt and an inline note explaining the plan format for human readers.
- `elixir/README.md` — short paragraph + link to SPEC.

---

## 10. Risk & mitigations

| Risk | Mitigation |
|---|---|
| Planner agent writes plan but forgets to label children | Plan parser detects: any `sub_issues[*].id` lacking `symphony:todo` label after a polling cycle is auto-labeled by the orchestrator (defensive backfill). |
| Plan races with new sub-issues added later | v1 limitation; documented. Operator unblocks by manually deleting plan comment + epic-tracking label, which forces re-plan on next poll. |
| GitHub sub-issues API rate limits | Cache sub-issues lookup per polling tick; only call on `Todo` candidates that haven't yet been classified. |
| Old issues that pre-date the feature get re-planned unexpectedly | Detection only fires on `Todo` issues. An epic already past `Todo` is left alone. |
| Operator confusion: "why did parent stay open?" | Reaper logs why it left a parent open (e.g., "child #135 still in `In Progress`"). Dashboard surfaces this. |

---

## 11. Implementation order (high-level — detailed plan to follow)

1. `GitHub.Client.fetch_sub_issues/1` + `fetch_issue_comments/1` — pure API, easy to test.
2. `GitHub.EpicPlan` module + tests.
3. `GitHub.StateMapping` extension for `epic-tracking`.
4. `prompt_builder.ex` + Workflow schema — variant support.
5. `WORKFLOW.alpha.md` planner template.
6. `GitHub.Adapter` integration — `blocked_by` population from plan.
7. Orchestrator: epic-detection + planner dispatch + reaper.
8. Memory tracker: optional sub_issues support for tests.
9. Integration tests covering all scenarios from §8.
10. SPEC.md update + specs.check pass.

---

## 12. Open questions to resolve during planning

- Where exactly does the orchestrator inject the planner dispatch — in `orchestrator.ex` near the existing dispatch path (around `:1062`), or as a pre-filter before? Implementation plan should pin this down.
- Should the planner agent run share the same workspace (clone) as a regular run? It doesn't write code, so a workspace clone is wasteful. Decide: skip `after_create` hook for planner runs vs. accept the extra ~5s clone time. Lean toward skipping, but quantify in plan.
- YAML library choice (`yamerl` vs `YamlElixir`). `mix.lock` review needed — defer to plan step.
