defmodule CMS.Recovery.Hydrator do
  require Logger
  alias CMS.{Node, NodeHead, NodeBody, NodeTail, NodeAntenna, DataHead, DataTail, Edge}
  alias CMS.NodeSupervisor

  @moduledoc """
  Responsible for "Hydrating" (loading) existing nodes from Epoch Logs into active RAM processes.
  Refined for CDMS Phase 1.
  """

  @epoch_dir "priv/data/epochs"

  @doc """
  Main entry point for hydration. Scans epoch logs and spawns node processes.
  """
  def run do
    Logger.info("HYDRATOR: Beginning CDMS Hydration Protocol...")
    
    File.mkdir_p!(@epoch_dir)
    
    files = 
      File.ls!(@epoch_dir)
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.sort()
      |> Enum.map(&Path.join(@epoch_dir, &1))

    if files == [] do
      Logger.info("HYDRATOR: No epoch logs found. Skipping hydration.")
    else
      Logger.info("HYDRATOR: Found #{length(files)} files. Loading nodes...")
      
      nodes_map = load_nodes_from_logs(files)
      
      Logger.info("HYDRATOR: Loaded #{map_size(nodes_map)} nodes from disk. Spawning processes...")
      
      spawn_nodes(nodes_map)
    end
    
    :ok
  end

  defp load_nodes_from_logs(files) do
    Enum.reduce(files, %{}, fn path, acc_sys ->
      File.stream!(path)
      |> Stream.map(fn line -> 
        case Jason.decode(line) do
          {:ok, data} -> data
          {:error, _} -> nil
        end
      end)
      |> Enum.reduce(acc_sys, fn 
           %{"entity" => "node", "type" => type, "data" => d}, acc 
             when type in ["node_created", "node_updated"] -> 
               Map.put(acc, d["id"], d)
           _, acc -> acc
         end)
    end)
  end

  defp spawn_nodes(nodes_map) do
    Enum.each(nodes_map, fn {id, node_map} ->
      try do
        node = reconstruct_node(node_map)
        case NodeSupervisor.start_child(node) do
          {:ok, pid} -> 
            # Register with LiveWire for file monitoring
            if node.body && node.body.data_ledger && node.body.data_ledger.physical_symlink do
              path = node.body.data_ledger.physical_symlink
              CMS.Services.LiveWire.watch(path)
              CMS.SymbolicIndex.register_path(path, pid)
              Logger.debug("HYDRATOR: Registered node #{id} with LiveWire and SymbolicIndex: #{path}")
            end
            :ok
          {:error, {:already_started, pid}} -> 
            # Also register already-started nodes
            if node.body && node.body.data_ledger && node.body.data_ledger.physical_symlink do
              path = node.body.data_ledger.physical_symlink
              CMS.Services.LiveWire.watch(path)
              CMS.SymbolicIndex.register_path(path, pid)
            end
            :ok
          {:error, reason} -> 
            Logger.error("HYDRATOR: Failed to start node #{id}: #{inspect(reason)}")
        end
      rescue
        e -> 
          Logger.error("HYDRATOR: Error reconstructing node #{id}: #{inspect(e)}")
          Logger.error(Exception.format(:error, e, __STACKTRACE__))
      end
    end)
  end

  def reconstruct_node(node_map) do
    head_map = node_map["head"]
    body_map = node_map["body"]
    head_data_map = body_map["data_head"]
    ledger_map = body_map["data_ledger"]
    antenna_map = node_map["antenna"]
    tail_map = node_map["tail"]

    # 1. Reconstruct Head
    # Convert spatial_coords from list back to tuple
    coords = case head_map["spatial_coords"] do
      [x, y, z] -> {x, y, z}
      coords when is_tuple(coords) -> coords  # Backward compatibility
      _ -> {0.0, 0.0, 0}  # Default fallback
    end
    
    node_head = %NodeHead{
      uuid: node_map["id"],
      embedding: Nx.tensor(head_map["embedding"]),
      embedding_model_version: head_map["embedding_model_version"],
      relevance_threshold: head_map["relevance_threshold"] || 0.35,
      internal_state: String.to_atom(head_map["internal_state"] || "genesis"),
      spatial_coords: coords,
      width_descriptor: head_map["width_descriptor"] || "m0"
    }

    # 2. Reconstruct Body Components
    data_head = %DataHead{
      summary: head_data_map["summary"],
      concepts: head_data_map["concepts"] || []
    }

    data_ledger = %DataTail{
      physical_symlink: ledger_map["physical_symlink"],
      integrity_hash: ledger_map["integrity_hash"],
      mime_definition: ledger_map["mime_definition"],
      last_mutation: parse_datetime(ledger_map["last_mutation"]),
      salience_score: ledger_map["salience_score"] || 0.5,
      chrono_stack: reconstruct_chrono_stack(ledger_map["chrono_stack"])
    }

    raw_body = body_map["data_body"]
    
    body_content = 
      if body_map["data_body_is_base64"] && is_binary(raw_body) do
        case Base.decode64(raw_body) do
          {:ok, decoded} -> decoded
          _ -> raw_body
        end
      else
        raw_body
      end

    node_body = %NodeBody{
      data_head: data_head,
      data_body: body_content,
      data_ledger: data_ledger,
      mode: String.to_atom(body_map["mode"] || "deep")
    }

    # 3. Reconstruct Tail (Connectome)
    node_tail = %NodeTail{
      hierarchical: reconstruct_edges(tail_map["hierarchical"]),
      syntactic: reconstruct_edges(tail_map["syntactic"]),
      semantic: reconstruct_edges(tail_map["semantic"])
    }

    # 4. Reconstruct Antenna
    node_antenna = %NodeAntenna{
      gain: antenna_map["gain"] || 1.0,
      frequency: antenna_map["frequency"] || 100,
      resonance_pattern: antenna_map["resonance_pattern"] || "stable",
      dampening_factors: antenna_map["dampening_factors"] || ["signal_established"]
    }

    %Node{
      id: node_map["id"],
      head: node_head,
      body: node_body,
      tail: node_tail,
      antenna: node_antenna,
      created_at: parse_datetime(node_map["created_at"]),
      last_fired: parse_datetime(node_map["last_fired"])
    }
  end

  defp reconstruct_edges(nil), do: []
  defp reconstruct_edges(list) when is_list(list) do
    Enum.map(list, fn e ->
      %Edge{
        target_node_id: e["target_node_id"],
        type: String.to_atom(e["type"]),
        weight: e["weight"] || 1.0,
        last_used_at: parse_datetime(e["last_used_at"])
      }
    end)
  end

  defp parse_datetime(nil), do: DateTime.utc_now()
  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_datetime(_), do: DateTime.utc_now()

  defp reconstruct_chrono_stack(%{"snapshots" => snapshots}) when is_list(snapshots) do
    %CMS.ChronoStack{
      snapshots: Enum.map(snapshots, &reconstruct_snapshot/1)
    }
  end
  defp reconstruct_chrono_stack(_), do: %CMS.ChronoStack{snapshots: []}

  defp reconstruct_snapshot(s) do
    %CMS.ChronoStack.Snapshot{
      timestamp: parse_datetime(s["timestamp"]),
      hash: s["hash"],
      diff: s["diff"],
      cause: String.to_atom(s["cause"] || "unknown")
    }
  end
end

