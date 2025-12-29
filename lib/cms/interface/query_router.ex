defmodule CMS.QueryRouter do
  use GenStage
  require Logger

  @moduledoc """
  The Valve: A GenStage Producer that regulates query traffic.

  Implements Backpressure (Gap 8) by buffering requests and only dispatching
  when the BusPipeline (Consumer) demands work.
  """

  # Configuration
  @buffer_size 10_000

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Public API to broadcast a query.
  It finds the active Broadway producer for BusPipeline and casts the event.
  """
  def broadcast_query(query_context, target_regions) do
    case Broadway.producer_names(CMS.BusPipeline) do
      [producer_pid | _] ->
        GenStage.cast(producer_pid, {:broadcast, query_context, target_regions})
      [] ->
        Logger.error("CMS.QueryRouter: No active producer found for BusPipeline.")
        {:error, :bus_not_ready}
    end
  end

  # Callbacks

  @impl true
  def init(_opts) do
    # State per spec: {queue, queue_count, pending_demand}
    # Broadway will pass buffer_size via producer options in BusPipeline
    {:producer, {:queue.new(), 0, 0}}
  end

  @impl true
  def handle_cast({:broadcast, context, regions}, {queue, count, demand}) do
    if count >= @buffer_size and demand == 0 do
      Logger.warning("QueryRouter: Buffer full. Dropping query #{context.query_id}.")
      {:noreply, [], {queue, count, demand}}
    else
      # Enqueue and dispatch
      new_queue = :queue.in({context, regions}, queue)
      new_count = count + 1
      
      {events, final_queue, final_count, final_demand} = dispatch_available(new_queue, new_count, demand)
      {:noreply, events, {final_queue, final_count, final_demand}}
    end
  end

  @impl true
  def handle_demand(incoming_demand, {queue, count, pending_demand}) do
    total_demand = incoming_demand + pending_demand
    {events, new_queue, new_count, new_demand} = dispatch_available(queue, count, total_demand)
    {:noreply, events, {new_queue, new_count, new_demand}}
  end

  # --- Internal Dispatch ---
  
  defp dispatch_available(queue, count, demand) do
    to_take = min(count, demand)
    
    if to_take > 0 do
      {events, new_queue} = take_n(queue, to_take, [])
      {events, new_queue, count - to_take, demand - to_take}
    else
      {[], queue, count, demand}
    end
  end

  defp take_n(queue, 0, acc), do: {Enum.reverse(acc), queue}
  defp take_n(queue, n, acc) do
    {{:value, item}, rest} = :queue.out(queue)
    take_n(rest, n - 1, [item | acc])
  end
end
