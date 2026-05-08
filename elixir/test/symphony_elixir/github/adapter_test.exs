defmodule SymphonyElixir.GitHub.AdapterTest do
  use ExUnit.Case, async: false
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Workflow}
  alias SymphonyElixir.GitHub.{Adapter, ClientStub}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/name",
      tracker_api_token: "test"
    )

    prev_client = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, ClientStub)

    on_exit(fn ->
      if prev_client do
        Application.put_env(:symphony_elixir, :github_client_module, prev_client)
      else
        Application.delete_env(:symphony_elixir, :github_client_module)
      end
    end)

    :ok
  end

  describe "fetch_sub_issues/1" do
    test "delegates to the configured Client module" do
      ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})
      assert {:ok, [134, 135]} = Adapter.fetch_sub_issues("133")
    end
  end
end
