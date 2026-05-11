defmodule SymphonyElixir.GitHub.AdapterTest do
  use ExUnit.Case, async: false
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{Adapter, ClientStub}
  alias SymphonyElixir.Workflow

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

  describe "fetch_candidate_issues with epic plan" do
    test "children inherit blocked_by from the parent epic's plan comment" do
      epic =
        ClientStub.sample_issue(
          id: "100",
          identifier: "100",
          state: "Epic Tracking",
          assigned_to_worker: false,
          labels: ["symphony:epic-tracking"]
        )

      child134 = ClientStub.sample_issue(id: "134", identifier: "134", state: "Todo", labels: ["symphony:todo"])
      child135 = ClientStub.sample_issue(id: "135", identifier: "135", state: "Todo", labels: ["symphony:todo"])

      plan_body = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: 134
          blocked_by: []
        - id: 135
          blocked_by: [134]
      <!-- /symphony-plan -->
      """

      ClientStub.set(:fetch_candidate_issues, {:ok, [epic, child134, child135]})
      ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})
      ClientStub.set(:fetch_issue_comments, {:ok, [%{id: 1, body: plan_body, updated_at: ~U[2026-05-08 12:00:00Z]}]})

      {:ok, issues} = Adapter.fetch_candidate_issues()

      by_id = Map.new(issues, &{&1.id, &1})
      assert by_id["134"].blocked_by == []
      assert [%{state: "Todo"}] = by_id["135"].blocked_by
    end

    test "child whose blocker is Done is unblocked" do
      epic = ClientStub.sample_issue(id: "100", state: "Epic Tracking", assigned_to_worker: false, labels: ["symphony:epic-tracking"])
      child134 = ClientStub.sample_issue(id: "134", identifier: "134", state: "Done", labels: ["symphony:done"])
      child135 = ClientStub.sample_issue(id: "135", identifier: "135", state: "Todo", labels: ["symphony:todo"])

      plan_body = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: 134
          blocked_by: []
        - id: 135
          blocked_by: [134]
      <!-- /symphony-plan -->
      """

      ClientStub.set(:fetch_candidate_issues, {:ok, [epic, child134, child135]})
      ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})
      ClientStub.set(:fetch_issue_comments, {:ok, [%{id: 1, body: plan_body, updated_at: ~U[2026-05-08 12:00:00Z]}]})

      {:ok, issues} = Adapter.fetch_candidate_issues()
      by_id = Map.new(issues, &{&1.id, &1})
      assert [%{state: "Done"}] = by_id["135"].blocked_by
    end

    test "blocker child that has been Done & dropped from candidates is fetched via fetch_issue_states_by_ids" do
      epic =
        ClientStub.sample_issue(
          id: "100",
          state: "Epic Tracking",
          assigned_to_worker: false,
          labels: ["symphony:epic-tracking"]
        )

      # Note: child134 (Done) is NOT in fetch_candidate_issues result —
      # simulating GitHub's "open only" filter on the candidates query.
      child135 =
        ClientStub.sample_issue(
          id: "135",
          identifier: "135",
          state: "Todo",
          labels: ["symphony:todo"]
        )

      plan_body = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: 134
          blocked_by: []
        - id: 135
          blocked_by: [134]
      <!-- /symphony-plan -->
      """

      ClientStub.set(:fetch_candidate_issues, {:ok, [epic, child135]})
      ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})

      ClientStub.set(
        :fetch_issue_comments,
        {:ok, [%{id: 1, body: plan_body, updated_at: ~U[2026-05-08 12:00:00Z]}]}
      )

      # Stub: when adapter looks up #134 (which is missing from candidates),
      # return it as Done so the blocker on #135 reflects terminal state.
      ClientStub.set(
        :fetch_issue_states_by_ids,
        {:ok,
         [
           ClientStub.sample_issue(
             id: "134",
             identifier: "134",
             state: "Done",
             labels: ["symphony:done"]
           )
         ]}
      )

      {:ok, issues} = Adapter.fetch_candidate_issues()
      by_id = Map.new(issues, &{&1.id, &1})
      assert [%{state: "Done"}] = by_id["135"].blocked_by
    end

    test "non-epic candidates pass through with blocked_by unchanged" do
      # Sanity check: when there's no epic in the candidates, fetch_candidate_issues
      # behaves identically to the wrapped Client call (no blocked_by mutation).
      plain = ClientStub.sample_issue(id: "200", identifier: "200", state: "Todo", labels: ["symphony:todo"])

      ClientStub.set(:fetch_candidate_issues, {:ok, [plain]})
      # No epic, so fetch_issue_comments should not be called by the adapter.
      # We don't configure fetch_issue_comments here — if the adapter calls it, ClientStub raises.

      assert {:ok, [^plain]} = Adapter.fetch_candidate_issues()
    end
  end

  describe "fetch_plan/1 sub-issue validation" do
    test "fetch_plan rejects a plan that references an unknown sub-issue id" do
      bad_plan = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: 134
          blocked_by: []
        - id: 999
          blocked_by: []
      <!-- /symphony-plan -->
      """

      ClientStub.set(:fetch_issue_comments, {:ok, [%{id: 1, body: bad_plan, updated_at: ~U[2026-05-10 12:00:00Z]}]})
      ClientStub.set(:fetch_sub_issues, {:ok, [134]})

      assert {:error, {:plan_references_unknown_ids, [999]}} = Adapter.fetch_plan("100")
    end

    test "fetch_plan rejects a plan that omits a real sub-issue" do
      partial_plan = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: 134
          blocked_by: []
      <!-- /symphony-plan -->
      """

      ClientStub.set(:fetch_issue_comments, {:ok, [%{id: 1, body: partial_plan, updated_at: ~U[2026-05-10 12:00:00Z]}]})
      ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})

      assert {:error, {:plan_missing_sub_issues, [135]}} = Adapter.fetch_plan("100")
    end

    test "fetch_plan accepts a plan whose ids exactly match the sub-issues" do
      good_plan = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: 134
          blocked_by: []
        - id: 135
          blocked_by: [134]
      <!-- /symphony-plan -->
      """

      ClientStub.set(:fetch_issue_comments, {:ok, [%{id: 1, body: good_plan, updated_at: ~U[2026-05-10 12:00:00Z]}]})
      ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})

      assert {:ok, plan} = Adapter.fetch_plan("100")
      assert length(plan.sub_issues) == 2
    end
  end
end
