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

    # 2. Distribute Binding Tasks via functional streams
    uuids
    |> Task.async_stream(&bind_node/1,
      max_concurrency: System.schedulers_online() * 2,
      timeout: :infinity
    )
    |> Stream.run()

    Logger.info("System Mixer: Phase 2 (Binding) complete.")
    :ok
  end

  @doc """
  Binds a single node to its peers using pure functional mapping.
  """
  def bind_node(uuid) do
    case NodeSupervisor.get_node(uuid) do
      {:ok, node} ->
        perform_bind(uuid, node)

      _error ->
        # PRODUCTION GRADE: Attempt on-demand hydration if node is inactive
        case NodeSupervisor.start_node_from_store(uuid) do
          {:ok, _pid} ->
            case NodeSupervisor.get_node(uuid) do
              {:ok, node} -> perform_bind(uuid, node)
              _ -> {:error, :hydration_failed}
            end
          _ ->
            Logger.warning("System Mixer: Node #{uuid} could not be hydrated. Skipping.")
            {:error, :missing}
        end
    end
  end

  defp perform_bind(uuid, node) do
    current_hash = node.body.data_ledger.integrity_hash
    last_hash = node.body.data_ledger.last_linked_hash
    
    if current_hash != last_hash or last_hash == nil do
       processed_node = CMS.Core.Logic.EdgeGenerator.generate_edges(node)
       
       if processed_node != node do
         NodeSupervisor.update_node(processed_node)
         Logger.debug("System Mixer: Bound node #{uuid}")
       end
    end
    :ok
  end
end
