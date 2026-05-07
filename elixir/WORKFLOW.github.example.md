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
    # --add-label is idempotent; --remove-label tolerates the case where the label
    # was already removed (retry / resumed dispatch).
    gh issue edit {{ issue.identifier }} --repo your-org/your-repo \
      --add-label symphony:in-progress
    gh issue edit {{ issue.identifier }} --repo your-org/your-repo \
      --remove-label symphony:todo 2>/dev/null || true
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
