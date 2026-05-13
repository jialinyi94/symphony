defmodule SymphonyElixir.PullRequest.Review do
  @moduledoc """
  A single GitHub review on a PR. `state` is normalized to an atom so
  stage predicates can pattern-match cleanly.
  """

  defstruct [:author_login, :state, :commit_id, :submitted_at, :body]

  @type review_state :: :approved | :changes_requested | :commented | :dismissed | :pending

  @type t :: %__MODULE__{
          author_login: String.t() | nil,
          state: review_state() | nil,
          commit_id: String.t() | nil,
          submitted_at: DateTime.t() | nil,
          body: String.t() | nil
        }

  @doc """
  Convert a GitHub API state string (uppercase) to a normalized atom.
  """
  @spec normalize_state(String.t() | nil) :: review_state()
  def normalize_state("APPROVED"), do: :approved
  def normalize_state("CHANGES_REQUESTED"), do: :changes_requested
  def normalize_state("COMMENTED"), do: :commented
  def normalize_state("DISMISSED"), do: :dismissed
  def normalize_state("PENDING"), do: :pending
  def normalize_state(other) when is_binary(other), do: :commented
  def normalize_state(_), do: :commented
end

defmodule SymphonyElixir.PullRequest do
  @moduledoc """
  Normalized pull-request representation used by `WorkItem` and PR-aware
  stage predicates.

  Tracker adapters translate native PR payloads (today: GitHub REST) into
  this struct so stage logic stays tracker-agnostic.

  Designed to carry _enough_ information for the canonical PR stages
  (`pr_first_review`, `pr_changes_requested`, `pr_ci_failed`,
  `pr_revalidate`, `pr_record_proof`) without forcing predicates to do
  follow-up IO. The orchestrator preloads `:latest_reviews_by_author`
  and `:ci_status` before resolving stages.
  """

  alias SymphonyElixir.PullRequest.Review

  defstruct [
    :number,
    :head_sha,
    :head_ref,
    :state,
    :draft,
    :url,
    :title,
    :body,
    :author_login,
    :linked_issue_number,
    latest_reviews_by_author: %{},
    reviews: [],
    ci_status: :unknown,
    created_at: nil,
    updated_at: nil
  ]

  @type pr_state :: :open | :closed | :merged
  @type ci_status :: :success | :failure | :pending | :unknown | :neutral

  @type t :: %__MODULE__{
          number: pos_integer() | nil,
          head_sha: String.t() | nil,
          head_ref: String.t() | nil,
          state: pr_state() | nil,
          draft: boolean() | nil,
          url: String.t() | nil,
          title: String.t() | nil,
          body: String.t() | nil,
          author_login: String.t() | nil,
          linked_issue_number: pos_integer() | nil,
          latest_reviews_by_author: %{String.t() => Review.t()},
          reviews: [Review.t()],
          ci_status: ci_status(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Returns the latest review by a given login, or `nil` if none.
  """
  @spec latest_review_from(t(), String.t()) :: Review.t() | nil
  def latest_review_from(%__MODULE__{latest_reviews_by_author: by_author}, login)
      when is_binary(login) and is_map(by_author) do
    Map.get(by_author, login)
  end

  def latest_review_from(_pr, _login), do: nil

  @doc """
  True when a reviewer's latest review approves the **current** PR head
  (i.e. their review's `commit_id` matches `pr.head_sha`).
  """
  @spec approved_by?(t(), String.t()) :: boolean()
  def approved_by?(%__MODULE__{} = pr, login) do
    case latest_review_from(pr, login) do
      %Review{state: :approved, commit_id: sha} when is_binary(sha) ->
        sha == pr.head_sha

      _ ->
        false
    end
  end

  @doc """
  True when a reviewer's latest review is CHANGES_REQUESTED **and** the
  author has not pushed any new commits since.
  """
  @spec changes_requested_by?(t(), String.t()) :: boolean()
  def changes_requested_by?(%__MODULE__{} = pr, login) do
    case latest_review_from(pr, login) do
      %Review{state: :changes_requested, commit_id: sha} when is_binary(sha) ->
        sha == pr.head_sha

      _ ->
        false
    end
  end

  @doc """
  True when the author has pushed new commits **after** the latest review
  by the given login — meaning the reviewer should revalidate.
  """
  @spec author_pushed_since?(t(), String.t()) :: boolean()
  def author_pushed_since?(%__MODULE__{head_sha: head_sha} = pr, login)
      when is_binary(head_sha) do
    case latest_review_from(pr, login) do
      %Review{commit_id: review_sha} when is_binary(review_sha) ->
        review_sha != head_sha

      _ ->
        # No prior review → "pushed since" is undefined / false.
        false
    end
  end

  def author_pushed_since?(_pr, _login), do: false
end
