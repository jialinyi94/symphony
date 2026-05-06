defmodule SymphonyElixir.GitHub.StateMapping do
  @moduledoc """
  Convention for mapping Symphony workflow states to/from GitHub issue labels.

  GitHub issues only have two intrinsic states (open, closed). Symphony needs
  finer-grained workflow states ("Todo", "In Progress", "Human Review", ...).
  We encode these as labels with a `symphony:` prefix, e.g. `symphony:in-progress`.

  ## Read direction (GitHub -> Symphony state name)

  `state_from_labels(labels, github_state)` is called when normalizing a GitHub
  issue into the Issue struct. It must:
    - Return one of the configured workflow state names (active or terminal)
    - Be deterministic when multiple `symphony:*` labels are present
    - Define a default for issues with no `symphony:*` label

  ## Write direction (Symphony state name -> label op)

  `label_ops_for_state(target_state, current_labels)` is called by
  `update_issue_state/2`. It must return:
    - `{:add, [label]}` for labels to attach
    - `{:remove, [label]}` for labels to detach (typically previous symphony:* labels)

  ## Why this lives in its own module

  Two reasons. (1) The convention here is a policy decision — different teams
  will want different mappings (you might prefer `state:in-progress` over
  `symphony:in-progress`, or want to fold "Rework" into "In Progress"). (2) It
  isolates the convention from the GitHub REST plumbing, so changes to the
  mapping don't risk breaking the API client.
  """

  @prefix "symphony:"

  @doc """
  Maps a Symphony workflow state name (as it appears in WORKFLOW.md's
  active_states / terminal_states) to the GitHub label name that represents it.

  Default convention: lowercase, replace spaces with hyphens, prefix with
  "symphony:". Example: "Human Review" -> "symphony:human-review".
  """
  @spec state_to_label(String.t()) :: String.t()
  def state_to_label(state_name) when is_binary(state_name) do
    @prefix <> (state_name |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, "-"))
  end

  @doc """
  Reads a Symphony workflow state name from a GitHub issue's labels and
  intrinsic state.

  TODO(you): implement. Reasonable starting policy:

    1. If a `symphony:*` label is present, decode it back to the original
       state name (you'll need to invert `state_to_label/1`, OR just match
       against the configured active_states/terminal_states list passed in).
    2. If no `symphony:*` label and `github_state == "open"`, return the
       first active state (convention: "Todo"). This is what GitHub-native
       users will hit when they create a fresh issue without labels.
    3. If no `symphony:*` label and `github_state == "closed"`, return the
       first terminal state ("Done").

  Return value MUST be a string that appears in either the active_states or
  terminal_states list from the tracker config — otherwise the orchestrator
  won't recognize it.
  """
  @spec state_from_labels([String.t()], String.t(), [String.t()], [String.t()]) :: String.t()
  def state_from_labels(labels, _github_state, active_states, terminal_states) do
    all_states = active_states ++ terminal_states

    labels
    |> Enum.filter(&symphony_label?/1)
    |> Enum.sort()
    |> List.first()
    |> case do
      nil -> hd(terminal_states)
      label -> Enum.find(all_states, hd(terminal_states), &(state_to_label(&1) == label))
    end
  end

  @doc """
  Returns the label add/remove operations needed to transition an issue to
  `target_state`.

  TODO(you): implement. Reasonable starting policy:

    - Add `state_to_label(target_state)`
    - Remove every existing `symphony:*` label (so the new state is
      unambiguous when read back via `state_from_labels/4`)

  Return shape: `[{:add, label_name}, {:remove, label_name}, ...]`
  """
  @spec label_ops_for_state(String.t(), [String.t()]) :: [{:add | :remove, String.t()}]
  def label_ops_for_state(target_state, current_labels) do
    target_label = state_to_label(target_state)

    removes =
      current_labels
      |> Enum.filter(&symphony_label?/1)
      |> Enum.reject(&(&1 == target_label))
      |> Enum.map(&{:remove, &1})

    adds = if target_label in current_labels, do: [], else: [{:add, target_label}]

    removes ++ adds
  end

  @doc """
  Helper: is this label one of ours? Useful for filtering during read/write.
  """
  @spec symphony_label?(String.t()) :: boolean()
  def symphony_label?(label) when is_binary(label), do: String.starts_with?(label, @prefix)
end
