defmodule CMS.Recovery.Rehydrator do
  require Logger
  alias CMS.VectorRouter

  @moduledoc """
  The "Builder". Executes the protocol to wipe incompatible caches and rebuild
  state from the immutable Epoch Logs (Source of Truth).
  """

  def rehydrate do
    Logger.warning("REHYDRATOR: Beginning Scorched Earth Protocol...")

    # 1. Purge Caches (Destructive)
    purge_caches()

    # 2. Re-Initialize Infrastructure
    Logger.info("REHYDRATOR: Temporarily starting persistence layer for restoration...")
    
    # Ensure mnesia is stopped before we try starting it for re-init
    :mnesia.stop()
    :mnesia.start()
    
    # We use start_link to ensure they are up
    {:ok, _} = CMS.EpochManager.start_link([])
    {:ok, _} = CMS.VectorRouter.start_link([])
    
    # 3. Stream & Reconstruct
    epoch_dir = "priv/data/epochs"
    File.mkdir_p!(epoch_dir)
    epoch_files = 
      File.ls!(epoch_dir)
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.sort() 
      |> Enum.map(&Path.join(epoch_dir, &1))

    Logger.info("REHYDRATOR: Found #{length(epoch_files)} epoch files. Starting reconstruction stream.")
    
    stats = Enum.reduce(epoch_files, %{nodes: 0, vectors: 0, errors: 0}, fn path, acc ->
       process_epoch_file(path, acc)
    end)
    
    Logger.info("REHYDRATOR: Reconstruction Complete. Stats: #{inspect(stats)}")
    
    # 4. Commit to Disk
    VectorRouter.persist()
    
    # 5. Cleanup
    GenServer.stop(CMS.EpochManager)
    GenServer.stop(CMS.VectorRouter)
    # CRITICAL: Stop mnesia so the main Application can start it properly with its own config
    :mnesia.stop()
    
    Logger.info("REHYDRATOR: Protocol Complete. System ready for fresh boot.")
  end
  
  defp purge_caches do
    :mnesia.stop()
    mnesia_dir = Application.get_env(:mnesia, :dir) || "priv/data/mnesia_store"
    File.rm_rf!(mnesia_dir)
    File.mkdir_p!(mnesia_dir) 
    
    vector_dir = "priv/data/hnsw_indices" 
    File.rm_rf!(vector_dir)
    Logger.info("REHYDRATOR: Burnt Mnesia and Vector Caches.")
  end
  
  defp process_epoch_file(path, stats) do
    File.stream!(path)
    |> Enum.reduce(stats, fn line, acc -> 
      try do
        event = Jason.decode!(line)
        apply_event(event, acc)
      rescue
        _ -> Map.update!(acc, :errors, &(&1 + 1))
      end
    end)
  end
  
  defp apply_event(%{"type" => "node_created", "data" => node_map}, acc) do
     restore_node(node_map, acc)
  end
  
  defp apply_event(%{"type" => "node_updated", "data" => node_map}, acc) do
     restore_node(node_map, acc)
  end
  
  # Silent catch for hebbian updates in rehydrator V1
  defp apply_event(%{"type" => "hebbian_update"}, acc), do: acc

  defp apply_event(_, acc), do: acc 
  
  defp restore_node(node_map, acc) do
     id = node_map["id"]
     head = node_map["head"]
     
     acc = Map.update!(acc, :nodes, &(&1 + 1))
     
     # Reconstruct the full Node struct to ensure we have all fields
     # We use the Hydrator's logic which handles Base64 decoding, tuples, etc.
     try do
       node = CMS.Recovery.Hydrator.reconstruct_node(node_map)
       
       # Restore to Mnesia
       # Table schema: [:uuid, :path_hash, :parent_uuid, :head_data, :body_data, :tail_data, :chrono_stack, :provenance]
       path_hash = UUID.uuid5(:oid, node.body.data_ledger.physical_symlink)
       parent_uuid = case Enum.find(node.tail.hierarchical, fn e -> e.type == :child_of end) do
         %CMS.Edge{target_node_id: pid} -> pid
         _ -> nil
       end
       
       :mnesia.dirty_write({:nodes_table, node.id, path_hash, parent_uuid, node.head, node.body, node.tail, node.body.data_ledger.chrono_stack, node.provenance, node.antenna})

       if head do
         embedding_list = head["embedding"]
         model = head["embedding_model_version"]
         
         if embedding_list do
           tensor = Nx.tensor(embedding_list)
           VectorRouter.add_embedding(id, tensor, model)
           Map.update!(acc, :vectors, &(&1 + 1))
         else
           acc
         end
       else
         acc
       end
     rescue
       e ->
         Logger.error("REHYDRATOR: Failed to restore node #{id}: #{inspect(e)}")
         Map.update!(acc, :errors, &(&1 + 1))
     end
  end
end
