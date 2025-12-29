defmodule CMS.NodeDriftManager do
  use GenServer
  require Logger

  alias CMS.{NodeSupervisor, SemanticRegion, LogAppender}

  @moduledoc """
  Monitors and repairs Semantic Region Drift.

  Implements Section 11.4: Node Migration Logic (Gap 11).

  CRITICAL UPDATE: Uses Task.async_stream for high-concurrency, non-blocking checks.
  """

  # Configuration
  @check_interval :timer.minutes(30)
  @batch_size 100 # Batch size is now used as the max_concurrency for throttling checks

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Process.send_after(self(), :check_drift, @check_interval)
    {:ok, %{}}
  end

  @impl true
  # --- CONCURRENCY REFACTOR: Using Task.async_stream for efficient checking ---
  def handle_info(:check_drift, state) do
    Logger.debug("NodeDriftManager: Initiating topology alignment check.")

    nodes_to_check = NodeSupervisor.get_all_active_node_pids()

    # Task.async_stream provides throttled concurrency control
    nodes_to_check
    |> Task.async_stream(&check_node/1, max_concurrency: @batch_size)
    |> Enum.each(fn
      {:ok, result} ->
        # Result is either :migrated or :noop, which is handled by check_node/1's side effects
        result
      {:error, reason} ->
        Logger.error("NodeDriftManager: Async check failed: #{inspect(reason)}")
    end)

    Logger.info("NodeDriftManager: Dispatched checks for #{length(nodes_to_check)} nodes.")

    Process.send_after(self(), :check_drift, @check_interval)
    {:noreply, state}
  end

  # --- FUNCTION REFACTOR: Removed redundant Task.start wrapper ---
  defp check_node(pid) do
    try do
      # Note: This is a synchronous call, but the caller (handle_info) runs it concurrently.
      {node_id, embedding, model_version, current_region_id} =
        GenServer.call(pid, :get_drift_info, 5000)

      correct_region_id = SemanticRegion.compute_region_hash(embedding, model_version)

      if correct_region_id != current_region_id do
        migrate_node(pid, node_id, current_region_id, correct_region_id)
        :migrated
      else
        :noop
      end
    catch
      _, _ -> :noop # Node likely decayed, crashed, or call timed out during check
    end
  end

  def migrate_node(pid, node_id, old_region, new_region) do
    CMS.SemanticRegion.unsubscribe(old_region, node_id)
    GenServer.cast(pid, {:update_region, new_region})
    CMS.SemanticRegion.subscribe(new_region, node_id)

    # CRITICAL: Append migration event to the log for auditability
    LogAppender.append_node_event(node_id, :node_migrated, %{
      previous_region: old_region,
      new_region: new_region,
      reason: "semantic_drift_correction"
    })

    Logger.info("Node #{node_id} migrated to Region #{new_region}.")
  end
end
