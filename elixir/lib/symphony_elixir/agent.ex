defmodule SymphonyElixir.Agent do
  @moduledoc """
  Adapter boundary for coding agents (Codex, Claude Code, Gemini, ...).

  Symphony's `AgentRunner` talks to a single agent through this behaviour.
  Each implementation translates the callbacks below into whatever protocol
  its underlying CLI / SDK speaks (Codex app-server JSON-RPC, Claude Agent
  SDK, etc.).

  ## Choosing the callback shape

  The questions you must answer before filling this in:

  1. Does the agent own session state across turns (Codex), or does the
     caller resequence the full message history every turn (raw chat APIs)?
  2. Is `run_turn` synchronous-with-callback (current Codex pattern: blocks
     until turn completes, streams events via `on_message`) or async-stream
     (returns an event stream the caller iterates)?
  3. Do approval / sandbox policies belong on `start_session` (per-session)
     or on each `run_turn` (per-turn)?

  See SPEC.md §"Codex App Server contract" for the inherited assumptions.
  """

  alias SymphonyElixir.{Config, Role}

  @callback start_session(workspace :: String.t(), opts :: keyword()) ::
              {:ok, session :: term()} | {:error, term()}

  @callback run_turn(session :: term(), prompt :: String.t(), issue :: struct(), opts :: keyword()) ::
              {:ok, summary :: map()} | {:error, term()}

  @callback stop_session(session :: term()) :: :ok

  @spec start_session(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    adapter = pick_adapter(opts)

    case adapter.start_session(workspace, opts) do
      {:ok, inner} -> {:ok, %{__adapter__: adapter, inner: inner}}
      other -> other
    end
  end

  @spec run_turn(term(), String.t(), struct()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue), do: run_turn(session, prompt, issue, [])

  @spec run_turn(term(), String.t(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{__adapter__: adapter, inner: inner}, prompt, issue, opts) do
    adapter.run_turn(inner, prompt, issue, opts)
  end

  def run_turn(session, prompt, issue, opts) do
    pick_adapter(opts).run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(term()) :: :ok
  def stop_session(%{__adapter__: adapter, inner: inner}), do: adapter.stop_session(inner)
  def stop_session(session), do: adapter().stop_session(session)

  @doc """
  Returns the runner module for the global `agent.kind` setting.

  Kept for callers that don't have a `Role` in hand (legacy tests).
  Production dispatch threads a role through `start_session/2` via
  `opts[:role]`; see `adapter_for_role/1`.
  """
  @spec adapter() :: module()
  def adapter do
    agent_kind_module(Config.settings!().agent.kind || "claude_code")
  end

  @doc """
  Pick the runner module for a given `Role` based on its `:agent_kind`.
  """
  @spec adapter_for_role(Role.t()) :: module()
  def adapter_for_role(%Role{agent_kind: kind}), do: agent_kind_module(kind)
  def adapter_for_role(_), do: adapter()

  defp pick_adapter(opts) do
    case Keyword.get(opts, :role) do
      %Role{} = role -> adapter_for_role(role)
      _ -> adapter()
    end
  end

  defp agent_kind_module("claude_code"), do: SymphonyElixir.ClaudeCode.Runner
  defp agent_kind_module("codex"), do: SymphonyElixir.Codex.AppServer
  defp agent_kind_module(_), do: SymphonyElixir.Codex.AppServer
end
