defmodule SymphonyElixir.WorkItem do
  @moduledoc """
  Unit of work observed by the orchestrator.

  Today a WorkItem wraps a single `Issue` and behaves identically to passing
  the Issue around directly. Future PRs will populate `attached_pr` so the
  same WorkItem can also represent the PR-review phase of the same logical
  task (review loops, revalidation, demo recording).

  The `metadata` map carries pre-computed values that stage predicates need
  but should not fetch themselves (e.g. `:has_sub_issues`). Keeping IO out
  of predicates lets `StageResolver` stay a pure function.
  """

  alias SymphonyElixir.{Issue, PullRequest}

  defstruct [
    :tracker_kind,
    :issue,
    :attached_pr,
    metadata: %{}
  ]

  @type tracker_kind :: atom() | nil

  # Permissive: accepts either a `PullRequest.t()` (preferred — used by the
  # GitHub adapter from PR3 forward) or a raw map (legacy / test fixtures).
  @type attached_pr :: PullRequest.t() | map() | nil

  @type t :: %__MODULE__{
          tracker_kind: tracker_kind(),
          issue: Issue.t() | nil,
          attached_pr: attached_pr(),
          metadata: map()
        }

  @doc """
  Build a WorkItem from an Issue.

  Options:

    * `:tracker_kind` — atom identifying the source tracker (`:github`, `:linear`, `:memory`)
    * `:metadata` — map of precomputed values used by stage predicates
      (e.g. `%{has_sub_issues: true}`)
    * `:attached_pr` — PR metadata when this WorkItem represents an
      issue-with-open-PR; defaults to `nil`
  """
  @spec from_issue(Issue.t(), keyword()) :: t()
  def from_issue(%Issue{} = issue, opts \\ []) do
    %__MODULE__{
      tracker_kind: Keyword.get(opts, :tracker_kind),
      issue: issue,
      attached_pr: Keyword.get(opts, :attached_pr),
      metadata: Keyword.get(opts, :metadata, %{}) |> normalize_metadata()
    }
  end

  @doc """
  Return the underlying Issue, or `nil` if the WorkItem is PR-only.
  """
  @spec issue(t()) :: Issue.t() | nil
  def issue(%__MODULE__{issue: issue}), do: issue

  @doc """
  Issue state as stored on the underlying Issue, or `nil` if absent.
  """
  @spec issue_state(t()) :: String.t() | nil
  def issue_state(%__MODULE__{issue: %Issue{state: state}}), do: state
  def issue_state(_), do: nil

  @doc """
  Lower-cased and trimmed issue state for predicate comparisons.

  Matches the normalization used by `SymphonyElixir.Orchestrator` and
  `SymphonyElixir.Config.Schema.normalize_issue_state/1` so predicates
  written here can compare against the same canonical strings.
  """
  @spec normalized_issue_state(t()) :: String.t() | nil
  def normalized_issue_state(%__MODULE__{} = wi) do
    case issue_state(wi) do
      state when is_binary(state) -> state |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  @doc """
  True when this WorkItem has an attached PR (review-phase work).
  """
  @spec has_attached_pr?(t()) :: boolean()
  def has_attached_pr?(%__MODULE__{attached_pr: nil}), do: false
  def has_attached_pr?(%__MODULE__{attached_pr: _pr}), do: true

  @doc """
  Returns the attached PullRequest struct when present, otherwise `nil`.

  Raw-map attachments (test fixtures / older code paths) are NOT
  promoted to PullRequest — callers that need a struct should produce
  one upstream. This keeps the helper unambiguous.
  """
  @spec pull_request(t()) :: PullRequest.t() | nil
  def pull_request(%__MODULE__{attached_pr: %PullRequest{} = pr}), do: pr
  def pull_request(_), do: nil

  @doc """
  Convenience predicate: PR is attached, open, and not draft.
  """
  @spec pr_open_for_review?(t()) :: boolean()
  def pr_open_for_review?(%__MODULE__{} = wi) do
    case pull_request(wi) do
      %PullRequest{state: :open, draft: draft} -> draft != true
      _ -> false
    end
  end

  @doc """
  Read a value from the metadata map with a default.
  """
  @spec metadata(t(), atom(), term()) :: term()
  def metadata(%__MODULE__{metadata: metadata}, key, default \\ nil)
      when is_atom(key) and is_map(metadata) do
    Map.get(metadata, key, default)
  end

  defp normalize_metadata(map) when is_map(map), do: map
  defp normalize_metadata(_), do: %{}
end
