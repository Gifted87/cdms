defmodule CMS.RegionalHebbianBuffer do
  use GenServer
  require Logger

  @moduledoc """
  A sharded buffer for accumulating Hebbian link weight adjustments.

  Implements Gap 5: Sharded Hebbian Buffer.
  Uses ETS for high-performance in-memory aggregation before flushing to the immutable log.
  """

  # Configuration
  @flush_interval 5_000 # Flush every 5 seconds
  @max_updates_before_flush 1_000 # Or if we hit 1000 pending updates

  defstruct [:shard_id, :ets_table, :update_count]

  # Client API

  def start_link(shard_id) do
    name = via_tuple(shard_id)
    GenServer.start_link(__MODULE__, shard_id, name: name)
  end

  @doc """
  Routes an update to the correct shard based on the node's region ID.

  adjustments: List of {target_node_id, weight_delta}
  e.g., [{"UUID-B", 0.05}, {"UUID-C", -0.01}]
  """
  @spec buffer_update(String.t(), list({String.t(), float()}), integer()) :: :ok
  def buffer_update(source_node_id, adjustments, semantic_region_id) do
    # Route to shard based on region ID (assuming 32 shards)
    shard_id = rem(semantic_region_id, 32)
    GenServer.cast(via_tuple(shard_id), {:buffer, source_node_id, adjustments})
  end

  # Server Callbacks

  @impl true
  def init(shard_id) do
    # Create a named public ETS table for this shard
    table_name = :"hebbian_buffer_#{shard_id}"
    ets_table = :ets.new(table_name, [:set, :named_table, :public])

    Logger.info("Hebbian Shard #{shard_id} started. ETS: #{inspect(table_name)}")

    # Schedule flush
    Process.send_after(self(), :flush, @flush_interval)

    {:ok, %__MODULE__{
      shard_id: shard_id,
      ets_table: ets_table,
      update_count: 0
    }}
  end

  @impl true
  def handle_cast({:buffer, source_id, adjustments}, state) do
    # Write to ETS.
    # Key: {source_id, target_id}
    # Value: Accumulated Delta

    Enum.each(adjustments, fn {target_id, delta} ->
      key = {source_id, target_id}

      # update_counter is atomic. If key doesn't exist, create it with default.
      # ETS update_counter usually works with integers. For floats, we must use
      # :ets.update_element or read/write inside the GenServer serialization.
      # Since we are inside handle_cast, we are serialized, so read/write is safe here.

      case :ets.lookup(state.ets_table, key) do
        [{^key, current_delta}] ->
          :ets.insert(state.ets_table, {key, current_delta + delta})
        [] ->
          :ets.insert(state.ets_table, {key, delta})
      end
    end)

    new_count = state.update_count + length(adjustments)

    if new_count >= @max_updates_before_flush do
      do_flush(state.ets_table)
      {:noreply, %{state | update_count: 0}}
    else
      {:noreply, %{state | update_count: new_count}}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush(state.ets_table)
    Process.send_after(self(), :flush, @flush_interval)
    {:noreply, %{state | update_count: 0}}
  end

  # Internals

  defp do_flush(table) do
    # 1. Drain table
    # This is a critical section. We use tab2list then delete_all.
    # In a ultra-high concurrency scenario, we might swap tables, but this suffices for now.
    entries = :ets.tab2list(table)
    :ets.delete_all_objects(table)

    unless Enum.empty?(entries) do
      Logger.debug("Flushing #{length(entries)} Hebbian updates to LogAppender.")

      # 2. Group by Source Node for efficient logging
      # Transform {{source, target}, delta} -> {source, [{target, delta}]}
      grouped_updates =
        entries
        |> Enum.group_by(
          fn {{source, _target}, _delta} -> source end,
          fn {{_source, target}, delta} -> [target, delta] end
        )

      # 3. Send to LogAppender (Step 7)
      CMS.LogAppender.append_hebbian_updates(grouped_updates)

      # 4. FEEDBACK LOOP: Apply updates to active NodeActors in real-time
      Enum.each(grouped_updates, fn {source_id, updates} ->
        # updates is a list of [target_id, delta]
        formatted_updates = Enum.map(updates, fn [target, delta] -> {target, delta} end)
        
        case Registry.lookup(CMS.NodeRegistry, source_id) do
          [{pid, _}] -> 
            GenServer.cast(pid, {:apply_hebbian_updates, formatted_updates})
          _ -> :ok
        end
      end)

      # --- NEW: Broadcast for Real-time Monitoring ---
      # This proves Neuroplasticity is happening
      total_updates = length(entries)
      sample = Enum.at(grouped_updates, 0)
      Phoenix.PubSub.broadcast(CMS.PubSub, "global:signals",
        {:hebbian_learning, %{update_count: total_updates, sample: sample}}
      )
    end
  end

  defp via_tuple(shard_id) do
    {:global, :"cms_hebbian_shard_#{shard_id}"}
  end
end
