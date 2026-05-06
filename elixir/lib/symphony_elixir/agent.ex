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

  alias SymphonyElixir.Config

  @callback start_session(workspace :: String.t(), opts :: keyword()) ::
              {:ok, session :: term()} | {:error, term()}

  @callback run_turn(session :: term(), prompt :: String.t(), issue :: struct(), opts :: keyword()) ::
              {:ok, summary :: map()} | {:error, term()}

  @callback stop_session(session :: term()) :: :ok

  @spec start_session(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def start_session(workspace, opts \\ []), do: adapter().start_session(workspace, opts)

  @spec run_turn(term(), String.t(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []),
    do: adapter().run_turn(session, prompt, issue, opts)

  @spec stop_session(term()) :: :ok
  def stop_session(session), do: adapter().stop_session(session)

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().agent.kind do
      "claude_code" -> SymphonyElixir.ClaudeCode.Runner
      _ -> SymphonyElixir.Codex.AppServer
    end
  end
end
