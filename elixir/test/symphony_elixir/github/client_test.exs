defmodule SymphonyElixir.GitHub.ClientTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.GitHub.Client

  @github_overrides [
    tracker_kind: "github",
    tracker_repo: "owner/name",
    tracker_api_token: "test-token",
    tracker_endpoint: nil,
    tracker_active_states: ["Todo", "In Progress"],
    tracker_terminal_states: ["Done", "Cancelled"]
  ]

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, body)
  end

  describe "fetch_issue_comments/1" do
    setup do
      bypass = Bypass.open()
      prev = Application.get_env(:symphony_elixir, :github_api_base)
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        if prev do
          Application.put_env(:symphony_elixir, :github_api_base, prev)
        else
          Application.delete_env(:symphony_elixir, :github_api_base)
        end
      end)

      %{bypass: bypass}
    end

    test "returns comments with id, body, updated_at", %{bypass: bypass} do
      write_workflow_file!(Workflow.workflow_file_path(), @github_overrides)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/comments", fn conn ->
        json_resp(
          conn,
          200,
          Jason.encode!([
            %{"id" => 1, "body" => "first comment", "updated_at" => "2026-05-08T10:00:00Z"},
            %{"id" => 2, "body" => "second comment", "updated_at" => "2026-05-08T11:00:00Z"}
          ])
        )
      end)

      assert {:ok, comments} = Client.fetch_issue_comments("133")
      assert [%{id: 1, body: "first comment"}, %{id: 2, body: "second comment"}] = comments
      assert %DateTime{} = hd(comments).updated_at
    end

    test "paginates when needed", %{bypass: bypass} do
      write_workflow_file!(Workflow.workflow_file_path(), @github_overrides)

      page1 = for n <- 1..100, do: %{"id" => n, "body" => "c#{n}", "updated_at" => "2026-05-08T10:00:00Z"}
      page2 = [%{"id" => 101, "body" => "c101", "updated_at" => "2026-05-08T11:00:00Z"}]

      Bypass.expect(bypass, "GET", "/repos/owner/name/issues/133/comments", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        page = String.to_integer(conn.query_params["page"] || "1")
        payload = if page == 1, do: page1, else: page2
        json_resp(conn, 200, Jason.encode!(payload))
      end)

      assert {:ok, comments} = Client.fetch_issue_comments("133")
      assert length(comments) == 101
      assert Enum.map(comments, & &1.id) == Enum.to_list(1..101)
    end

    test "preserves order when last page is partial (2-page)", %{bypass: bypass} do
      write_workflow_file!(Workflow.workflow_file_path(), @github_overrides)

      page1 = for n <- 1..100, do: %{"id" => n, "body" => "c#{n}", "updated_at" => "2026-05-08T10:00:00Z"}
      page2 = for n <- 101..150, do: %{"id" => n, "body" => "c#{n}", "updated_at" => "2026-05-08T10:00:00Z"}

      Bypass.expect(bypass, "GET", "/repos/owner/name/issues/133/comments", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        page = String.to_integer(conn.query_params["page"] || "1")
        payload = if page == 1, do: page1, else: page2
        json_resp(conn, 200, Jason.encode!(payload))
      end)

      assert {:ok, comments} = Client.fetch_issue_comments("133")
      assert Enum.map(comments, & &1.id) == Enum.to_list(1..150)
    end
  end

  describe "fetch_sub_issues/1" do
    setup do
      bypass = Bypass.open()
      prev = Application.get_env(:symphony_elixir, :github_api_base)
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        if prev do
          Application.put_env(:symphony_elixir, :github_api_base, prev)
        else
          Application.delete_env(:symphony_elixir, :github_api_base)
        end
      end)

      %{bypass: bypass}
    end

    test "returns the parsed list of issue numbers from a 200 response", %{bypass: bypass} do
      write_workflow_file!(Workflow.workflow_file_path(), @github_overrides)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/sub_issues", fn conn ->
        body =
          Jason.encode!([
            %{"number" => 134, "title" => "schema"},
            %{"number" => 135, "title" => "migration"}
          ])

        json_resp(conn, 200, body)
      end)

      assert {:ok, [134, 135]} = Client.fetch_sub_issues("133")
    end

    test "returns empty list when GitHub returns 200 with []", %{bypass: bypass} do
      write_workflow_file!(Workflow.workflow_file_path(), @github_overrides)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/sub_issues", fn conn ->
        json_resp(conn, 200, "[]")
      end)

      assert {:ok, []} = Client.fetch_sub_issues("133")
    end

    test "returns error tuple on HTTP error", %{bypass: bypass} do
      write_workflow_file!(Workflow.workflow_file_path(), @github_overrides)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/sub_issues", fn conn ->
        json_resp(conn, 404, ~s({"message":"not found"}))
      end)

      assert {:error, {:github_http_error, 404, _}} = Client.fetch_sub_issues("133")
    end
  end

  describe "normalize_issue (via fetch_candidate_issues)" do
    setup do
      bypass = Bypass.open()
      prev = Application.get_env(:symphony_elixir, :github_api_base)
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        if prev do
          Application.put_env(:symphony_elixir, :github_api_base, prev)
        else
          Application.delete_env(:symphony_elixir, :github_api_base)
        end
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/name",
        tracker_api_token: "test",
        tracker_active_states: ["Todo", "In Progress", "Epic Tracking"],
        tracker_terminal_states: ["Human Review", "Done"]
      )

      %{bypass: bypass}
    end

    test "Epic Tracking issues get assigned_to_worker: false", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues", fn conn ->
        json_resp(
          conn,
          200,
          Jason.encode!([
            %{
              "number" => 1,
              "title" => "epic",
              "body" => "",
              "state" => "open",
              "html_url" => "https://x",
              "labels" => [%{"name" => "symphony:epic-tracking"}],
              "created_at" => "2026-05-08T10:00:00Z",
              "updated_at" => "2026-05-08T10:00:00Z"
            }
          ])
        )
      end)

      {:ok, [issue]} = Client.fetch_candidate_issues()
      assert issue.state == "Epic Tracking"
      assert issue.assigned_to_worker == false
    end

    test "non-Epic Tracking issues retain assigned_to_worker: true", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues", fn conn ->
        json_resp(
          conn,
          200,
          Jason.encode!([
            %{
              "number" => 2,
              "title" => "regular",
              "body" => "",
              "state" => "open",
              "html_url" => "https://x",
              "labels" => [%{"name" => "symphony:todo"}],
              "created_at" => "2026-05-08T10:00:00Z",
              "updated_at" => "2026-05-08T10:00:00Z"
            }
          ])
        )
      end)

      {:ok, [issue]} = Client.fetch_candidate_issues()
      assert issue.state == "Todo"
      assert issue.assigned_to_worker == true
    end
  end

  describe "fetch_check_runs_conclusion/1 + fetch_ci_status/1" do
    setup do
      bypass = Bypass.open()
      prev = Application.get_env(:symphony_elixir, :github_api_base)
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        if prev do
          Application.put_env(:symphony_elixir, :github_api_base, prev)
        else
          Application.delete_env(:symphony_elixir, :github_api_base)
        end
      end)

      write_workflow_file!(Workflow.workflow_file_path(), @github_overrides)

      %{bypass: bypass}
    end

    defp check_runs_resp(runs), do: Jason.encode!(%{"total_count" => length(runs), "check_runs" => runs})
    defp run(conclusion), do: %{"id" => :rand.uniform(1_000_000), "conclusion" => conclusion}

    test "check_runs all success → :success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-1/check-runs", fn conn ->
        json_resp(conn, 200, check_runs_resp([run("success"), run("success"), run("neutral")]))
      end)

      assert {:ok, :success} = Client.fetch_check_runs_conclusion("sha-1")
    end

    test "any failure-class conclusion → :failure", %{bypass: bypass} do
      for conclusion <- ["failure", "timed_out", "action_required", "cancelled"] do
        Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-#{conclusion}/check-runs", fn conn ->
          json_resp(conn, 200, check_runs_resp([run("success"), run(conclusion)]))
        end)

        assert {:ok, :failure} = Client.fetch_check_runs_conclusion("sha-#{conclusion}")
      end
    end

    test "any null conclusion (in progress) → :pending", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-p/check-runs", fn conn ->
        json_resp(conn, 200, check_runs_resp([run("success"), run(nil)]))
      end)

      assert {:ok, :pending} = Client.fetch_check_runs_conclusion("sha-p")
    end

    test "empty check_runs list → :unknown", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-empty/check-runs", fn conn ->
        json_resp(conn, 200, check_runs_resp([]))
      end)

      assert {:ok, :unknown} = Client.fetch_check_runs_conclusion("sha-empty")
    end

    test "fetch_ci_status merges combined + check_runs: success + success = success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-x/status", fn conn ->
        json_resp(conn, 200, Jason.encode!(%{"state" => "success"}))
      end)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-x/check-runs", fn conn ->
        json_resp(conn, 200, check_runs_resp([run("success")]))
      end)

      assert {:ok, :success} = Client.fetch_ci_status("sha-x")
    end

    test "fetch_ci_status: combined :pending + check_runs :failure → :failure", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-mix/status", fn conn ->
        json_resp(conn, 200, Jason.encode!(%{"state" => "pending"}))
      end)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-mix/check-runs", fn conn ->
        json_resp(conn, 200, check_runs_resp([run("failure")]))
      end)

      assert {:ok, :failure} = Client.fetch_ci_status("sha-mix")
    end

    test "fetch_ci_status: legacy-only repo (no check_runs, combined :success) → :success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-legacy/status", fn conn ->
        json_resp(conn, 200, Jason.encode!(%{"state" => "success"}))
      end)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-legacy/check-runs", fn conn ->
        json_resp(conn, 200, check_runs_resp([]))
      end)

      assert {:ok, :success} = Client.fetch_ci_status("sha-legacy")
    end

    test "fetch_ci_status: Actions-only repo (combined returns phantom pending with empty statuses, check_runs :success) → :success — regression for PR #5", %{bypass: bypass} do
      # The ACTUAL response shape from GitHub on Actions-only repos
      # (empirically verified by reviewer-is-all-u-need on this PR head):
      # `{"state": "pending", "statuses": []}` — NOT `state: nil`. The
      # first version of this test mocked `state: nil` and so happened
      # to pass against a broken implementation. fetch_combined_status
      # now detects empty `statuses` and returns :unknown so check-runs
      # can win the merge.
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-actions/status", fn conn ->
        json_resp(conn, 200, Jason.encode!(%{"state" => "pending", "statuses" => []}))
      end)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-actions/check-runs", fn conn ->
        json_resp(conn, 200, check_runs_resp([run("success"), run("success")]))
      end)

      assert {:ok, :success} = Client.fetch_ci_status("sha-actions")
    end

    test "fetch_combined_status: phantom 'pending' with empty statuses → :unknown (not :pending)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-empty/status", fn conn ->
        json_resp(conn, 200, Jason.encode!(%{"state" => "pending", "statuses" => []}))
      end)

      assert {:ok, :unknown} = Client.fetch_combined_status("sha-empty")
    end

    test "fetch_combined_status: real pending state with at least one status → :pending", %{bypass: bypass} do
      # Sanity check: when there IS a real underlying status integration
      # reporting pending, we propagate :pending (NOT swallow into :unknown).
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-real-pending/status", fn conn ->
        json_resp(
          conn,
          200,
          Jason.encode!(%{
            "state" => "pending",
            "statuses" => [
              %{"context" => "ci/circleci", "state" => "pending"}
            ]
          })
        )
      end)

      assert {:ok, :pending} = Client.fetch_combined_status("sha-real-pending")
    end

    test "fetch_ci_status propagates errors from either underlying call", %{bypass: bypass} do
      # Use 401 (auth error) — non-transient, so Req does not retry. 5xx
      # would be retried per Req's default :safe_transient policy and
      # Bypass.expect_once would not match the retries.
      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-err/status", fn conn ->
        json_resp(conn, 200, Jason.encode!(%{"state" => "success"}))
      end)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/commits/sha-err/check-runs", fn conn ->
        json_resp(conn, 401, ~s({"message":"unauthorized"}))
      end)

      assert {:error, {:github_http_error, 401, _}} = Client.fetch_ci_status("sha-err")
    end
  end
end
