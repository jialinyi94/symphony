defmodule SymphonyElixir.StageReviewerLoginTest do
  @moduledoc """
  `Stage.reviewer_login/0` is the lookup key for `latest_reviews_by_author`.
  The map is keyed by logins normalized at the GitHub adapter boundary
  (suffix `[bot]` stripped), so the configured value must be normalized
  on the way out too — otherwise an operator who writes the literal
  GitHub bot login (e.g. `"reviewer-is-all-u-need[bot]"`) gets silent
  predicate misses with no error.

  Marked `async: false` because the tests mutate global application env.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.Stage

  setup do
    prior = Application.get_env(:symphony_elixir, :reviewer_login)

    on_exit(fn ->
      if prior == nil do
        Application.delete_env(:symphony_elixir, :reviewer_login)
      else
        Application.put_env(:symphony_elixir, :reviewer_login, prior)
      end
    end)

    :ok
  end

  describe "reviewer_login/0" do
    test "returns the documented default when env is unset" do
      Application.delete_env(:symphony_elixir, :reviewer_login)
      assert Stage.reviewer_login() == "reviewer-is-all-u-need"
    end

    test "returns the configured login verbatim when it has no [bot] suffix" do
      Application.put_env(:symphony_elixir, :reviewer_login, "alice-reviewer")
      assert Stage.reviewer_login() == "alice-reviewer"
    end

    test "strips trailing [bot] suffix so the value matches normalized map keys" do
      Application.put_env(:symphony_elixir, :reviewer_login, "reviewer-is-all-u-need[bot]")
      assert Stage.reviewer_login() == "reviewer-is-all-u-need"
    end

    test "is idempotent — normalizing an already-normalized value is a no-op" do
      Application.put_env(:symphony_elixir, :reviewer_login, "reviewer-is-all-u-need")
      assert Stage.reviewer_login() == "reviewer-is-all-u-need"
    end
  end
end
