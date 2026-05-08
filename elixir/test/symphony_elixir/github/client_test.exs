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
        json_resp(conn, 200, Jason.encode!([
          %{"id" => 1, "body" => "first comment", "updated_at" => "2026-05-08T10:00:00Z"},
          %{"id" => 2, "body" => "second comment", "updated_at" => "2026-05-08T11:00:00Z"}
        ]))
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
end
