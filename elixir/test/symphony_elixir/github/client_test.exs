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

  describe "fetch_sub_issues/1" do
    test "returns the parsed list of issue numbers from a 200 response" do
      bypass = Bypass.open()
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")
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

    test "returns empty list when GitHub returns 200 with []" do
      bypass = Bypass.open()
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")
      write_workflow_file!(Workflow.workflow_file_path(), @github_overrides)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/sub_issues", fn conn ->
        json_resp(conn, 200, "[]")
      end)

      assert {:ok, []} = Client.fetch_sub_issues("133")
    end

    test "returns error tuple on HTTP error" do
      bypass = Bypass.open()
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")
      write_workflow_file!(Workflow.workflow_file_path(), @github_overrides)

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/sub_issues", fn conn ->
        json_resp(conn, 404, ~s({"message":"not found"}))
      end)

      assert {:error, {:github_http_error, 404, _}} = Client.fetch_sub_issues("133")
    end
  end
end
