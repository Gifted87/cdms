defmodule CMS.Services.SystemMixer do
  @moduledoc """
  The System Mixer: Orchestrates the 'Binding' phase of the Genesis workflow.
  Triggers live nodes to re-establish their syntactic and semantic edges once
  the population is stabilized.
  """

  require Logger
  alias CMS.NodeSupervisor

  @doc """
  Performs a system-wide bind operation on all established nodes.
  """
  def bind_all do
    Logger.info("System Mixer: Starting Phase 2 (Binding)...")
    
    # 1. Retrieve all node UUIDs from Mnesia
    # Table: :nodes_table, Attributes: [:uuid, :path_hash, :parent_uuid, :head_data, :body_data, :tail_data, :chrono_stack]
    uuids = :mnesia.dirty_all_keys(:nodes_table)
    
    Logger.info("System Mixer: Establishing connections for #{length(uuids)} nodes.")

    # 2. Distribute Binding Tasks in parallel
    uuids
    |> Enum.map(fn uuid ->
      Task.async(fn -> bind_node(uuid) end)
    end)
    |> Enum.each(&Task.await(&1, :infinity))

    # 3. Stabilization Period (Scatter-Gather Wavefront)
    # We wait a brief moment for semantic proposals to be processed by the actors.
    Logger.info("System Mixer: Waiting for semantic gathering to stabilize...")
    Process.sleep(500)

    Logger.info("System Mixer: Phase 2 (Binding) complete.")
    :ok
  end

  @doc """
  Binds a single node to its peers.
  """
  def bind_node(uuid) do
    case NodeSupervisor.get_node_pid(uuid) do
      nil ->
        Logger.warning("System Mixer: Node #{uuid} not active. Skipping.")
        {:error, :not_active}
      pid ->
        # Trigger recompute_edges on the NodeActor
        case GenServer.call(pid, :recompute_edges, 60_000) do
          {:ok, _node} -> 
            Logger.debug("System Mixer: Bound node #{uuid}")
            :ok
          error -> 
            Logger.error("System Mixer: Failed to bind node #{uuid}: #{inspect(error)}")
            error
        end
    end
  end
end
