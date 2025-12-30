defmodule CMS.BroadcastCoordinator do
  use GenServer
  require Logger

  @moduledoc """
  Coordinates the broadcasting of queries to ALL nodes in the system.
  
  This coordinator implements the decentralized cognitive model where every node
  receives every query and makes its own autonomous decision about relevance.
  """

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Broadcasts a query to all nodes in the system.
  """
  def broadcast_query(query_context) do
    GenServer.cast(__MODULE__, {:broadcast_query, query_context})
  end

  @doc """
  Broadcasts a node's semantic profile for others to 'Gather' relevance.
  """
  def scatter_semantic_profile(source_uuid, embedding) do
    GenServer.cast(__MODULE__, {:scatter_semantic_profile, source_uuid, embedding})
  end

  def init(_opts) do
    {:ok, %{}}
  end

  def handle_cast({:broadcast_query, query_context}, state) do
    # Get all active node PIDs and broadcast the query to each one
    all_pids = CMS.NodeSupervisor.get_all_active_node_pids()
    
    Logger.info("[BROADCAST] Query #{String.slice(query_context.query_id, 0, 8)} → #{length(all_pids)} nodes")
    
    Enum.each(all_pids, fn pid ->
      send(pid, {:query, query_context})
    end)
    
    {:noreply, state}
  end

  def handle_cast({:scatter_semantic_profile, source_uuid, embedding}, state) do
    # Broadcast to a specific PubSub topic for semantic gathering
    Phoenix.PubSub.broadcast(CMS.PubSub, "semantic_gather", {:semantic_scatter, source_uuid, embedding})
    {:noreply, state}
  end
end