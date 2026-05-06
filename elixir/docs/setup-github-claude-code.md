# Setup: Symphony with GitHub + Claude Code

End-to-end setup for running Symphony against a GitHub repo using Claude Code
as the coding agent. This is the configuration produced by Tasks #1-#6 of the
agent-agnostic fork.

## Prerequisites

1. **Elixir 1.19.5 + OTP 28** — `cd elixir && mise install` (uses `mise.toml`).
2. **`claude` CLI** on PATH — Claude Code 2.x. Verify with `claude --version`.
3. **GitHub personal access token** with `repo` scope. Export as `GITHUB_TOKEN`.
4. **A GitHub repo you can clone** that you want Symphony to manage.

## Configure your repo

In the repo Symphony will work on, add the workflow file at the repo root:

```bash
cp elixir/WORKFLOW.github.example.md /path/to/your/repo/WORKFLOW.md
```

Edit the new `WORKFLOW.md`:

* `tracker.repo`: set to `"<your-gh-org>/<your-repo>"`
* `hooks.after_create`: replace the `git clone` URL with your repo
* `agent.kind`: leave as `"claude_code"` (or set to `"codex"`)
* `claude_code.model`: optional, defaults to your Claude Code CLI default

## Label issues for Symphony to pick them up

Symphony uses the **conservative** state policy: it only touches issues that
already carry a `symphony:*` label. Create at minimum these labels in your repo
(GitHub UI → Labels → New label):

| Label | Purpose |
|-------|---------|
| `symphony:todo` | Marks an issue as ready for Symphony |
| `symphony:in-progress` | Set by the agent when starting work |
| `symphony:human-review` | Set by the agent when waiting on human |
| `symphony:done` | Terminal — Symphony will close the issue |

State names in `WORKFLOW.md` (`active_states`, `terminal_states`) are mapped
to these labels via `lib/symphony_elixir/github/state_mapping.ex`.

## Run Symphony

```bash
cd elixir
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxx
mise exec -- mix run --no-halt
```

Or build the escript:

```bash
mise exec -- mix build
GITHUB_TOKEN=ghp_xxx ./bin/symphony
```

Symphony will:

1. Poll `GET https://api.github.com/repos/<owner>/<repo>/issues?state=open`
   every `polling.interval_ms` (default 30s).
2. Filter open issues whose labels decode to one of `tracker.active_states`
   (i.e. they have `symphony:todo` or `symphony:in-progress`).
3. For each candidate issue not already running, claim it, create a workspace
   under `workspace.root`, run `hooks.after_create` (clones the repo), then
   spawn `claude` with the rendered prompt.
4. Repeat turns until the issue's state moves out of active states or
   `agent.max_turns` is reached.

## Dashboard

If `observability.dashboard_enabled: true` and `server.port` is set, Symphony
serves a Phoenix LiveView dashboard at `http://<host>:<port>/` showing
running sessions, token usage (Codex only — Claude Code MVP doesn't surface
this yet), and rate-limit info.

## Troubleshooting

* **Issue not picked up** — confirm it has `symphony:todo` label and is **open**.
  Conservative policy = unlabeled issues are treated as terminal.
* **"missing_github_api_token"** — `GITHUB_TOKEN` env var is not set or
  `tracker.api_key` in WORKFLOW.md isn't `"${GITHUB_TOKEN}"`.
* **Claude turn fails immediately** — try running the same `claude -p`
  command manually in the workspace dir to reproduce. The Symphony log
  will show the spawned argv.
* **Workspace path errors** — `workspace.root` must exist and be writable.
  Identifiers from GitHub are issue numbers; safe for filesystem.
