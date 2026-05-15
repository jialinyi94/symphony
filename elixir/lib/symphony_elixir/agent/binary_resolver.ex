defmodule SymphonyElixir.Agent.BinaryResolver do
  @moduledoc """
  Resolve an agent binary path so daemons (e.g. systemd --user) running
  with a stripped PATH can still locate user-installed binaries.

  Three input shapes, by priority:

    * Absolute path (`"/usr/bin/codex"`) — returned verbatim.
    * Tilde-prefixed (`"~/.local/bin/codex"`) — `Path.expand/1`'d so a
      WORKFLOW author can target a per-user install without baking the
      runtime PATH of the operator (e.g. systemd-managed Symphony whose
      service environment doesn't include `~/.local/bin`).
    * Bare name (`"codex"`) — looked up via `System.find_executable/1`.

  Raises `ArgumentError` when a bare name is not on PATH. This is the
  desired behavior: it surfaces a missing-binary as a startup-time
  configuration failure rather than letting the agent spawn cycle exit
  127 over and over.
  """

  @spec resolve!(String.t()) :: String.t()
  def resolve!(path), do: resolve!(path, [])

  @doc """
  Same as `resolve!/1` but accepts a `:label` option used in the
  `ArgumentError` message when PATH lookup fails. Useful so callers
  can produce `claude binary "x" not found on PATH` vs
  `codex binary "x" not found on PATH` without two near-duplicate
  implementations.
  """
  @spec resolve!(String.t(), keyword()) :: String.t()
  def resolve!("/" <> _ = path, _opts), do: path
  def resolve!("~" <> _ = path, _opts), do: Path.expand(path)

  def resolve!(name, opts) when is_binary(name) do
    case System.find_executable(name) do
      nil ->
        label = Keyword.get(opts, :label, "agent")
        raise ArgumentError, "#{label} binary #{inspect(name)} not found on PATH"

      path ->
        path
    end
  end
end
