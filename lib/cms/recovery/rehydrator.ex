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

    # Stop any running mnesia instance to ensure clean state
    :mnesia.stop()
    
    # Use the Bootloader safe logic to create tables before we start writing
    CMS.Persistence.Bootloader.ensure_schema_and_tables()

    # Now start Mnesia for the actual rehydration writing
    :mnesia.start()
    
    # We use start_link to ensure they are up
    {:ok, _} = CMS.EpochManager.start_link([])
    {:ok, _} = CMS.VectorRouter.start_link([])
    
    # 3. Stream & Reconstruct
    epoch_dir = epoch_dir()
    File.mkdir_p!(epoch_dir)
    epoch_files = 
      File.ls!(epoch_dir)
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.sort() 
      |> Enum.map(&Path.join(epoch_dir, &1))

    Logger.info("REHYDRATOR: Found #{length(epoch_files)} epoch files. Starting reconstruction stream.")
    
    # Initialize batch state
    initial_acc = %{
      nodes: 0, 
      vectors: 0, 
      errors: 0, 
      pending_vectors: %{},   # %{model => [{node_id, tensor}]}
      batch_size: 0
    }

    final_stats = Enum.reduce(epoch_files, initial_acc, fn path, acc ->
       process_epoch_file(path, acc)
    end)
    
    # Flush remaining vectors
    flush_vectors(final_stats.pending_vectors)
    
    Logger.info("REHYDRATOR: Reconstruction Complete. Stats: Nodes=#{final_stats.nodes}, Vectors=#{final_stats.vectors}, Errors=#{final_stats.errors}")
    
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
    
    vector_dir = vector_dir()
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
     
     new_nodes_count = acc.nodes + 1
     
     # Progress Log
     if rem(new_nodes_count, 500) == 0 do
       Logger.info("REHYDRATOR: Processed #{new_nodes_count} nodes...")
     end

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

       acc = %{acc | nodes: new_nodes_count}

       if head do
         embedding_list = head["embedding"]
         model = head["embedding_model_version"] || "nomic-embed-text" # Default fallback
         
         if embedding_list do
           tensor = Nx.tensor(embedding_list)
           
           # Queue for batching
           current_batch = Map.get(acc.pending_vectors, model, [])
           new_batch = [{id, tensor} | current_batch]
           
           new_pending = Map.put(acc.pending_vectors, model, new_batch)
           new_batch_size = acc.batch_size + 1
           
           # Check flush threshold
           if new_batch_size >= 500 do
              flush_vectors(new_pending)
              %{acc | pending_vectors: %{}, batch_size: 0, vectors: acc.vectors + new_batch_size}
           else
              %{acc | pending_vectors: new_pending, batch_size: new_batch_size}
           end
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

  defp flush_vectors(pending_map) do
    Enum.each(pending_map, fn {model, items} ->
      if length(items) > 0 do
        Logger.debug("REHYDRATOR: Flushing batch of #{length(items)} vectors for #{model}...")
    VectorRouter.bulk_add(items, model)
      end
    end)
  end

  defp epoch_dir do
    data_root = Application.get_env(:acn_cms, :data_root) || "priv/data"
    Path.join(data_root, "epochs")
  end

  defp vector_dir do
    data_root = Application.get_env(:acn_cms, :data_root) || "priv/data"
    Path.join(data_root, "hnsw_indices")
  end
end
