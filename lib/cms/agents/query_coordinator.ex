defmodule CMS.QueryCoordinator do
  use GenServer
  require Logger

  alias CMS.LogAppender

  @moduledoc """
  Orchestrates the lifecycle of a single query.

  Implements Gap 1: Global Inhibition / Winner-Takes-Most (WTM).

  It collects results from responding NodeActors.
  Optimization: Implements a "Gathering Window" to finalize queries immediately
  after results start arriving, avoiding fixed timeouts in broadcast mode.
  """

  # Configuration
  @inhibit_threshold_count 100  # If >100 nodes fire, trigger inhibition
  @query_timeout 10_000         # Max time to wait if NO results arrive
  @gathering_window 50          # NEW: Once first result arrives, wait only 50ms for others, then return.
  @inhibit_check_delay 150      # Check for explosion 150ms after start

  # State
  defstruct [
    :query_id,
    :origin_pid,
    :target_regions,
    :fired_nodes,    # Map: %{node_id => {relevance, node_data}}
    :top_k_list,     # List: [{relevance, node_id}, ...] sorted desc
    :active_regions, # MapSet of regions pending completion
    :inhibited?,     # Boolean
    :timeout_timer,   # Reference to the active timeout timer
    :max_results     # Integer or nil
  ]

  # API

  @doc """
  Starts a coordinator for a specific query.
  """
  def start_link(query_id, target_regions, origin_pid, opts \\ []) do
    max_results = Keyword.get(opts, :max_results)
    GenServer.start_link(__MODULE__, {query_id, target_regions, origin_pid, max_results}, name: via_tuple(query_id))
  end

  @doc """
  Called by a NodeActor when it decides to fire.
  """
  def node_fired(query_id, node_id, relevance, node_data) do
    case Registry.lookup(CMS.QueryCoordinatorRegistry, query_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:node_fired, node_id, relevance, node_data})
      [] ->
        Logger.warning("QueryCoordinator: Node #{node_id} attempted to fire for Query #{query_id}, but Coordinator not found.")
        :ok
    end
  end

  @doc """
  Called by the BusPipeline when a region has finished processing the initial broadcast.
  """
  def region_complete(query_id, region_id) do
    case Registry.lookup(CMS.QueryCoordinatorRegistry, query_id) do
      [{pid, _}] -> GenServer.cast(pid, {:region_complete, region_id})
      [] -> :ok
    end
  end

  # Callbacks

  @impl true
  def init({query_id, target_regions, origin_pid, max_results}) do
    Logger.debug("Coordinator #{query_id}: Initializing...")

    # Start the failsafe timeout (10s)
    timer_ref = Process.send_after(self(), :timeout, @query_timeout)

    # Rapid inhibition check
    Process.send_after(self(), :check_inhibition, @inhibit_check_delay)

    # CRITICAL FIX 1: Signal the caller (Web.Router) that the coordinator is ready.
    # This prevents the race condition where nodes fire before the coordinator is findable.
    send(origin_pid, {:coordinator_ready, query_id})
    Logger.debug("Coordinator #{query_id}: Ready signal sent to #{inspect(origin_pid)}.")

    {:ok, %__MODULE__{
      query_id: query_id,
      origin_pid: origin_pid,
      target_regions: target_regions,
      active_regions: MapSet.new(target_regions),
      fired_nodes: %{},
      top_k_list: [],
      inhibited?: false,
      timeout_timer: timer_ref,
      max_results: max_results
    }}
  end

  @impl true
  def handle_cast({:node_fired, node_id, relevance, node_data}, state) do
    # NEW LOGGING: Confirm receipt of fired node
    Logger.debug("Coordinator #{state.query_id}: Received fired node #{node_id} (Score: #{:io_lib.format("~.4f", [relevance])})")

    # CRITICAL FIX: Duplicate Prevention logic
    # We check if we already have this node. If we do, we only update if the new score is higher.
    should_update =
      case Map.get(state.fired_nodes, node_id) do
        {existing_score, _} when existing_score >= relevance -> false
        _ -> true
      end

    if should_update do
      # 1. Store Result
      new_fired = Map.put(state.fired_nodes, node_id, {relevance, node_data})

      # 2. Update Top-K (Insertion Sort / limited list / deduplication)
      new_top_k = update_top_k(state.top_k_list, {relevance, node_id}, state.max_results)

      # 3. Latency Optimization (The Gathering Window)
      new_timer =
        if map_size(state.fired_nodes) == 0 do
          Logger.debug("Coordinator #{state.query_id}: First result received. Switching to fast-path gathering window (#{@gathering_window}ms).")
          Process.cancel_timer(state.timeout_timer)
          Process.send_after(self(), :timeout, @gathering_window)
        else
          state.timeout_timer
        end

      new_state = %{state | fired_nodes: new_fired, top_k_list: new_top_k, timeout_timer: new_timer}

      # 4. Check Immediate Overload
      if not state.inhibited? and map_size(new_fired) > @inhibit_threshold_count do
        Logger.warning("Coordinator #{state.query_id}: Threshold exceeded (#{map_size(new_fired)} nodes). Triggering inhibition.")
        trigger_inhibition(state.query_id, state.active_regions)
        report_query_failure(state, :cognitive_overload)
        {:noreply, %{new_state | inhibited?: true}}
      else
        {:noreply, new_state}
      end
    else
      # Duplicate or lower score ignored
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:region_complete, region_id}, state) do
    new_active = MapSet.delete(state.active_regions, region_id)

    if MapSet.size(new_active) == 0 do
      Logger.debug("Coordinator #{state.query_id}: All regions complete. Finalizing.")
      # Cancel any pending timers since we are finishing explicitly
      Process.cancel_timer(state.timeout_timer)
      finalize_query(state)
      {:stop, :normal, state}
    else
      {:noreply, %{state | active_regions: new_active}}
    end
  end

  @impl true
  def handle_info(:check_inhibition, state) do
    # If we have a lot of results early on, prune the rest of the search.
    if not state.inhibited? and map_size(state.fired_nodes) > (@inhibit_threshold_count / 2) do
      Logger.debug("Coordinator #{state.query_id}: Fast inhibition triggered.")
      trigger_inhibition(state.query_id, state.active_regions)
      report_query_failure(state, :rapid_inhibition)
      {:noreply, %{state | inhibited?: true}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    # This handler is now dual-purpose:
    # 1. If 10s passed and NO results -> Report Timeout/Failure.
    # 2. If 50ms passed and RESULTS exist -> Return Results (Fast Path).

    result_count = map_size(state.fired_nodes)

    if result_count > 0 do
      Logger.info("Coordinator #{state.query_id}: Gathering window closed. Returning #{result_count} results.")
      finalize_query(state)
    else
      Logger.warning("Coordinator #{state.query_id} timed out with 0 results.")
      report_query_failure(state, :timeout)
      finalize_query(state)
    end

    {:stop, :normal, state}
  end

  # Internals

  defp trigger_inhibition(query_id, active_regions) do
    Enum.each(active_regions, fn region_id ->
      Phoenix.PubSub.broadcast(CMS.PubSub, "region:#{region_id}", {:inhibit, query_id})
    end)
  end

  defp report_query_failure(state, reason) do
    LogAppender.append_system_event(:query_failure, %{
      query_id: state.query_id,
      reason: reason,
      origin_pid: inspect(state.origin_pid),
      fired_node_count: map_size(state.fired_nodes),
      active_regions: MapSet.to_list(state.active_regions)
    })
  end

  defp finalize_query(state) do
    # Map top_k IDs back to full data
    results =
      state.top_k_list
      |> Enum.map(fn {_score, id} -> Map.get(state.fired_nodes, id) end)
      |> Enum.reject(&is_nil/1)

    Logger.info("Coordinator #{state.query_id}: Finalizing query with #{length(results)} top results.")

    # Send back to requestor
    send(state.origin_pid, {:query_result, state.query_id, results})
  end

  defp update_top_k(list, new_entry, max_results) do
    list = [new_entry | list]
    |> Enum.sort_by(fn {score, _} -> score end, :desc)
    |> Enum.uniq_by(fn {_, id} -> id end) # CRITICAL FIX: Deduplicate by ID
    
    if max_results && max_results > 0 do
      Enum.take(list, max_results)
    else
      list
    end
  end

  defp via_tuple(query_id) do
    {:via, Registry, {CMS.QueryCoordinatorRegistry, query_id}}
  end
end
