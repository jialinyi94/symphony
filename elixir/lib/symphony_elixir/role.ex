defmodule SymphonyElixir.Role do
  @moduledoc """
  Per-role dispatch configuration resolved from `WORKFLOW.md`'s `roles:`
  block (or implicit defaults when the block is absent).

  Symphony's stage dispatch reads a `Role` to decide:

    * **Which agent module to spawn** — based on `:agent_kind`
      (`"claude_code"` → `SymphonyElixir.ClaudeCode.Runner`,
      `"codex"` → `SymphonyElixir.Codex.AppServer`).
    * **Which command line** — `:command` overrides the runner's default
      binary path. When `nil`, the runner uses its own default
      (`"claude"` / `"codex app-server"`).
    * **Which identity to run as** — `:github_token_env` names an env var
      whose value the runner exports as `GITHUB_TOKEN` for the spawned
      child process. This is how the `reviewer` role authenticates as
      `reviewer-is-all-u-need` while the `implementer` role keeps the
      workspace user's token.

  A `nil` `:github_token_env` (or an env var that's missing at spawn
  time) means **no injection** — the child process inherits the parent
  Symphony service's environment. This preserves pre-roles behavior
  for unconfigured deployments (BC-safe).
  """

  defstruct [
    :id,
    :command,
    :github_token_env,
    agent_kind: "claude_code"
  ]

  @type agent_kind :: String.t()
  @type t :: %__MODULE__{
          id: String.t() | nil,
          agent_kind: agent_kind(),
          command: String.t() | nil,
          github_token_env: String.t() | nil
        }

  @doc """
  Build a Role from a raw config map (the value side of `roles:` in
  WORKFLOW.md) and a role id key. String keys + atom keys both
  accepted to play well with YAML-decoded maps.
  """
  @spec from_config(String.t(), map() | nil) :: t()
  def from_config(id, nil), do: %__MODULE__{id: id}

  def from_config(id, raw) when is_map(raw) do
    %__MODULE__{
      id: id,
      agent_kind: get(raw, :agent_kind, "claude_code"),
      command: get(raw, :command),
      github_token_env: get(raw, :github_token_env)
    }
  end

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  @doc """
  Resolve the `GITHUB_TOKEN` value to inject for this role, or `nil`
  when there is no override (child inherits parent env).
  """
  @spec resolve_token(t()) :: String.t() | nil
  def resolve_token(%__MODULE__{github_token_env: nil}), do: nil

  def resolve_token(%__MODULE__{github_token_env: var_name}) when is_binary(var_name) do
    case System.get_env(var_name) do
      "" -> nil
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  def resolve_token(_), do: nil
end
