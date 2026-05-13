---
tracker:
  kind: github
  repo: "your-org/your-repo"
  api_key: "${GITHUB_TOKEN}"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Cancelled
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo .
  before_run: |
    # Move issue to in-progress before the agent starts so dashboards (and humans)
    # see the active state immediately, not retroactively when the agent finishes.
    #
    # `sh -lc` (Workspace.run_hook) does not enable `set -e`, so the script's
    # exit status is the last command's. We chain with && so an add-label
    # failure (auth, network, missing gh) propagates as a hook failure rather
    # than being masked by the trailing `|| true`. The remove-label tolerates
    # the already-removed case (retry / resumed dispatch).
    gh issue edit {{ issue.identifier }} --repo your-org/your-repo \
      --add-label symphony:in-progress \
    && { gh issue edit {{ issue.identifier }} --repo your-org/your-repo \
           --remove-label symphony:todo 2>/dev/null || true; }
  before_remove: |
    true
agent:
  kind: claude_code   # or "codex"
  max_concurrent_agents: 2
  max_turns: 20

# Used when agent.kind == "claude_code"
claude_code:
  command: claude
  # model: "claude-sonnet-4-6"     # optional, falls back to CLI default
  # permission_mode: "bypassPermissions"
  # allowed_tools: "Bash,Edit,Read,Write,Grep"

# Used when agent.kind == "codex"
codex:
  command: codex --config 'model="gpt-5.5"' app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite

# (preview, follow-up integration) Roles let Symphony dispatch different
# stages with different agent identities — e.g. the implementer is
# Claude Code, but the reviewer runs as codex with a distinct GitHub
# token so PR reviews are posted as a separate bot account.
#
# Symphony's PR-review-loop stages (pr_first_review, pr_revalidate,
# pr_changes_requested, pr_ci_failed, pr_record_proof, pr_awaiting_merge)
# map onto these roles via Stage.dispatch_options/2. The Orchestrator
# wiring that consumes this block is delivered in a follow-up commit
# on this branch.
#
# roles:
#   implementer:
#     agent_kind: claude_code
#     command: ~/.local/bin/claude
#   reviewer:
#     agent_kind: codex
#     command: codex exec --skill gh-review-bot
#     github_token_env: REVIEWER_BOT_TOKEN

# Named prompts. Each stage's `prompt_variant` selects from this map.
# The default body (below the frontmatter) is used when variant=:default.
prompts:
  # Reviewer's first pass on a freshly-opened PR. Goal: catch obvious
  # correctness issues + post structured review comments.
  pr_first_review: |
    You are the **reviewer** identity for {{ tracker.repo }}.

    Review pull request `#{{ pr.number }}` (linked to issue
    `#{{ issue.identifier }}`). The PR head is `{{ pr.head_sha }}`.

    Goals:
      1. Read the diff via `gh pr diff {{ pr.number }} --repo {{ tracker.repo }}`.
      2. Identify correctness issues (logic bugs, off-by-one, regressions, missed edge cases).
      3. Verify tests cover the change — run the relevant subset locally if cheap.
      4. Post a single PR review using `gh pr review {{ pr.number }} --repo {{ tracker.repo }}`
         with one of: `--approve`, `--request-changes`, or `--comment`.
      5. Inline review comments for specific lines are encouraged for changes-requested.
      6. Stop after posting the review.

  # Author follow-up after reviewer requested changes OR CI failed.
  pr_author_followup: |
    You are the **implementer** for {{ tracker.repo }} PR `#{{ pr.number }}`
    (issue `#{{ issue.identifier }}`).

    Reviewer's latest feedback is on commit `{{ pr.head_sha }}`. Address it.

    Steps:
      1. `gh pr view {{ pr.number }} --comments --repo {{ tracker.repo }}` to read the
         most recent reviewer-is-all-u-need comments and any chatgpt-codex-connector
         findings.
      2. If CI failed, `gh run list --branch {{ pr.head_ref }} --repo {{ tracker.repo }}`
         and inspect failures.
      3. Make the smallest fix that addresses every blocking concern. Match
         existing repo style; do NOT take the opportunity to refactor.
      4. Run tests + lint locally.
      5. Commit + push to the same branch. Do NOT open a new PR.
      6. Stop — let the reviewer revalidate on the next cycle.

  # Reviewer revalidating after author pushed new commits.
  pr_revalidate: |
    You are the **reviewer** revisiting PR `#{{ pr.number }}` after the
    author pushed new commits. Current head: `{{ pr.head_sha }}`.

    Steps:
      1. Run `gh pr view {{ pr.number }} --json reviews --repo {{ tracker.repo }}`
         to see your prior review state.
      2. `gh pr diff {{ pr.number }} --repo {{ tracker.repo }}` for the new diff.
      3. Verify the changes actually address your prior feedback (not a partial fix).
      4. Run tests if scope changed materially.
      5. Post a new review: approve when satisfied, request-changes for unresolved items,
         comment for clarifying questions only.
      6. Stop.

  # Record proof of work after review converged + CI green.
  pr_record_proof: |
    Review on PR `#{{ pr.number }}` has converged: reviewer-is-all-u-need
    APPROVED on head `{{ pr.head_sha }}` and CI is green. Before the human
    merges, record proof-of-work artifacts.

    Produce, in a single PR comment:

    1. **Demo recording** — pick one form based on the change shape:
         * CLI / batch change → `asciinema rec /tmp/demo.cast --command 'uv run …'`
           then `asciinema upload /tmp/demo.cast` and embed the URL.
         * Notebook change   → `jupyter nbconvert --to html --execute demo.ipynb`
           and host on the workspace's `~/tmp/` (Tailscale URL).

    2. **Test summary** — copy the final lines of `mix test` / `uv run pytest -q`
       showing pass count + skipped + runtime.

    3. **Characterization gate** — if this PR is marked
       `migration/backward-compatible`, paste the byte-identical PnL diff (or
       confirm `rtol=0` with the regression test).

    4. Post all three above as ONE comment via:
         gh pr comment {{ pr.number }} --repo {{ tracker.repo }} --body-file -

    5. Add the `symphony:human-review` label so the orchestrator knows the
       PR is ready for the human merge decision:
         gh issue edit {{ issue.identifier }} --repo {{ tracker.repo }} \
           --add-label symphony:human-review

    6. Stop. Do NOT merge the PR yourself.

  # epic_planner (pre-existing) — kept here for reference.
  epic_planner: |
    [Your existing epic_planner prompt body lives here.]
---

You are working on GitHub issue `#{{ issue.identifier }}` in the `{{ tracker.repo }}` repository.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the issue is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
{% endif %}

Issue context:
Identifier: #{{ issue.identifier }}
Title: {{ issue.title }}
Current Symphony state: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
(no description provided)
{% endif %}

Your task:

1. Implement the change described in the issue.
2. Open a pull request when done; reference this issue with `Closes #{{ issue.identifier }}` in the PR body.
3. Once PR is opened and CI is green, remove the `symphony:in-progress` label and add `symphony:human-review`.
4. Stop the turn after the label transition. Do not wait for review.

Notes:
- Symphony has injected its own `GITHUB_TOKEN` into your environment so you can use `gh` CLI directly.
- The repo is already cloned at the workspace root. You are inside it.
- Keep changes minimal. Match the existing code style.
