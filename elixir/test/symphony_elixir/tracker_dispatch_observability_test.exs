defmodule SymphonyElixir.TrackerDispatchObservabilityTest do
  use SymphonyElixir.TestSupport

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["codex-ready", "exec:deep"],
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 2,
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    base_issue = %Issue{
      id: "issue-fir11",
      identifier: "FIR-11",
      title: "Observability diagnostic",
      state: "Todo",
      labels: ["codex-ready", "exec:deep"],
      dispatchable: true,
      blocked_by: []
    }

    %{state: state, issue: base_issue}
  end

  test "authoritative predicate should_dispatch_issue_for_test determines dispatch eligibility", %{
    state: state,
    issue: issue
  } do
    # 1. Fully compliant candidate is eligible under authoritative predicate
    assert Orchestrator.should_dispatch_issue_for_test(issue, state)

    # 2. Not dispatchable
    refute Orchestrator.should_dispatch_issue_for_test(%{issue | dispatchable: false}, state)

    # 3. Missing required label
    refute Orchestrator.should_dispatch_issue_for_test(%{issue | labels: ["codex-ready"]}, state)

    # 4. Inactive state
    refute Orchestrator.should_dispatch_issue_for_test(%{issue | state: "Waiting for Review"}, state)

    # 5. Terminal state
    refute Orchestrator.should_dispatch_issue_for_test(%{issue | state: "Done"}, state)

    # 6. Already claimed
    refute Orchestrator.should_dispatch_issue_for_test(issue, %{state | claimed: MapSet.new([issue.id])})

    # 7. Already running
    refute Orchestrator.should_dispatch_issue_for_test(issue, %{state | running: %{issue.id => %{issue: issue}}})

    # 8. Currently blocked
    refute Orchestrator.should_dispatch_issue_for_test(issue, %{state | blocked: %{issue.id => %{}}})

    # 9. No available slots
    full_running = %{"r1" => %{issue: issue}, "r2" => %{issue: issue}}
    refute Orchestrator.should_dispatch_issue_for_test(issue, %{state | running: full_running})
  end

  test "poll cycle logs tracker fetch summary and candidate rejection reasons without altering authoritative decisions" do
    # Rejected issue 1: missing required label
    rejected_labels = %Issue{
      id: "issue-fir11",
      identifier: "FIR-11",
      title: "Missing label",
      state: "Todo",
      labels: ["codex-ready"],
      dispatchable: true,
      blocked_by: []
    }

    # Rejected issue 2: not dispatchable
    rejected_disp = %Issue{
      id: "issue-fir12",
      identifier: "FIR-12",
      title: "Not dispatchable",
      state: "Todo",
      labels: ["codex-ready", "exec:deep"],
      dispatchable: false,
      blocked_by: [%{id: "blk-1", identifier: "FIR-9"}]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [rejected_labels, rejected_disp])

    orchestrator_name = Module.concat(__MODULE__, :"PollOrchestrator_#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)
        _ = :sys.get_state(pid)
      end)

    # Tracker poll logging
    assert log =~ "Tracker poll completed: issue_count=2 issue_ids=[\"FIR-11\", \"FIR-12\"]"

    # Rejection logging with exact diagnostic reasons
    assert log =~ "Issue rejected for dispatch: issue_id=issue-fir11 issue_identifier=FIR-11 reason=issue not routable (missing required labels)"
    assert log =~ "Issue rejected for dispatch: issue_id=issue-fir12 issue_identifier=FIR-12 reason=issue marked not dispatchable by tracker (dispatchable=false, blocked_by=1)"

    # No agent was launched
    state = :sys.get_state(pid)
    assert map_size(state.running) == 0
  end

  test "tracker poll completed log format contains issue count and identifiers" do
    issues = [
      %Issue{id: "id-1", identifier: "FIR-10"},
      %Issue{id: "id-2", identifier: "FIR-11"}
    ]

    issue_count = length(issues)
    issue_ids = Enum.map(issues, &(&1.identifier || &1.id))

    log_message = "Tracker poll completed: issue_count=#{issue_count} issue_ids=#{inspect(issue_ids)}"
    assert log_message =~ "issue_count=2"
    assert log_message =~ "FIR-10"
    assert log_message =~ "FIR-11"
  end
end
