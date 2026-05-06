defmodule SymphonyElixir.ClaudeCode.Runner do
  @moduledoc """
  Agent adapter that drives the Claude Code CLI (`claude`) as the coding agent.

  Each Symphony issue gets a UUIDv4 session id; turns within an issue reuse the
  same id via `--session-id`, letting Claude Code persist the conversation so
  subsequent turns can naturally continue the prior context.

  Sessions are spawned non-interactively (`-p`) with `stream-json` output, and
  events are forwarded to the caller's `on_message` callback as they arrive
  on stdout.

  ## Configuration (WORKFLOW.md `claude_code:` block, all optional)

      claude_code:
        command: "claude"          # binary on PATH or absolute path
        model: "claude-sonnet-4-6" # passed to --model; nil = CLI default
        permission_mode: "bypassPermissions"  # default uses --dangerously-skip-permissions
        allowed_tools: nil         # CSV passed via --allowedTools

  ## Limitations (MVP)

    * Local worker only (no SSH/Docker dispatch yet).
    * Approval policies are reduced to a single boolean: skip-permissions on/off.
    * No structured rate-limit / token-usage parsing — those events are forwarded
      to the on_message callback verbatim and the dashboard ignores them.
  """

  @behaviour SymphonyElixir.Agent

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  import Bitwise

  @port_line_bytes 1_048_576

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    if worker_host do
      {:error, {:unsupported_worker_host, worker_host}}
    else
      with {:ok, expanded} <- PathSafety.canonicalize(workspace) do
        session = %{
          session_id: generate_session_id(),
          workspace: expanded,
          worker_host: nil
        }

        {:ok, session}
      end
    end
  end

  @impl true
  def run_turn(%{session_id: session_id, workspace: workspace}, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    settings = claude_code_settings()
    claude_args = build_args(session_id, settings) ++ [prompt]

    Logger.info(
      "Claude Code turn starting for #{issue_context(issue)} session_id=#{session_id} workspace=#{workspace} prompt_bytes=#{byte_size(prompt)}"
    )

    sh = System.find_executable("sh") || raise ArgumentError, "sh not found on PATH"
    claude_bin = locate_binary!(settings.command)
    # Wrap claude in `sh -c 'exec "$@" </dev/null'` so claude sees stdin EOF
    # immediately and skips its 3s "no stdin data received" wait.
    sh_args = ["-c", "exec \"$@\" </dev/null", "--", claude_bin] ++ claude_args

    port =
      Port.open(
        {:spawn_executable, sh},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, @port_line_bytes},
          {:cd, workspace},
          {:args, sh_args}
        ]
      )

    case stream_loop(port, on_message, []) do
      {:ok, _events} ->
        Logger.info(
          "Claude Code turn completed for #{issue_context(issue)} session_id=#{session_id}"
        )

        {:ok, %{session_id: session_id, thread_id: session_id, turn_id: session_id}}

      {:error, reason} ->
        Logger.warning(
          "Claude Code turn failed for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @impl true
  def stop_session(_session), do: :ok

  defp build_args(session_id, settings) do
    base = [
      "-p",
      "--session-id",
      session_id,
      "--output-format",
      "stream-json",
      "--verbose"
    ]

    base
    |> add_permission_mode(settings.permission_mode)
    |> add_optional("--model", settings.model)
    |> add_optional("--allowedTools", settings.allowed_tools)
  end

  defp add_permission_mode(args, nil), do: args ++ ["--dangerously-skip-permissions"]
  defp add_permission_mode(args, "bypassPermissions"), do: args ++ ["--dangerously-skip-permissions"]
  defp add_permission_mode(args, mode), do: args ++ ["--permission-mode", mode]

  defp add_optional(args, _flag, nil), do: args
  defp add_optional(args, _flag, ""), do: args
  defp add_optional(args, flag, value), do: args ++ [flag, to_string(value)]

  defp stream_loop(port, on_message, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case decode_event(line) do
          {:ok, event} ->
            emit(on_message, event)
            stream_loop(port, on_message, [event | acc])

          {:error, _reason} ->
            emit(on_message, %{type: "raw", data: line})
            stream_loop(port, on_message, acc)
        end

      {^port, {:data, {:noeol, _partial}}} ->
        # Line longer than @port_line_bytes; treat as malformed.
        {:error, :line_too_long}

      {^port, {:exit_status, 0}} ->
        {:ok, Enum.reverse(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:claude_exit, status}}
    after
      :timer.minutes(30) ->
        Port.close(port)
        {:error, :turn_timeout}
    end
  end

  defp decode_event(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{} = event} -> {:ok, event}
      {:ok, other} -> {:error, {:non_object_event, other}}
      {:error, reason} -> {:error, {:json_decode_failed, reason}}
    end
  end

  defp emit(on_message, event) when is_function(on_message, 1), do: on_message.(event)
  defp emit(_on_message, _event), do: :ok

  defp claude_code_settings do
    settings = Config.settings!()

    case Map.get(settings, :claude_code) do
      nil ->
        %{command: "claude", model: nil, permission_mode: nil, allowed_tools: nil}

      claude_code ->
        %{
          command: Map.get(claude_code, :command) || "claude",
          model: Map.get(claude_code, :model),
          permission_mode: Map.get(claude_code, :permission_mode),
          allowed_tools: Map.get(claude_code, :allowed_tools)
        }
    end
  end

  defp locate_binary!("/" <> _ = path), do: path

  defp locate_binary!(name) do
    case System.find_executable(name) do
      nil -> raise ArgumentError, "claude binary #{inspect(name)} not found on PATH"
      path -> path
    end
  end

  defp generate_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = bor(band(c, 0x0FFF), 0x4000)
    d = bor(band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp issue_context(%{id: id, identifier: identifier}), do: "issue_id=#{id} issue_identifier=#{identifier}"
  defp issue_context(_), do: "issue=unknown"
end
