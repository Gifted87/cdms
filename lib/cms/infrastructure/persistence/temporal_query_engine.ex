defmodule CMS.TemporalQueryEngine do
  @moduledoc """
  Provides querying capabilities for the immutable history of the CMS.

  Implements Gap 3: Chrono-Stack & Temporal Queries.
  It queries the Mnesia index to find relevant Epoch Logs, then streams those logs
  to reconstruct the state of a node at a specific timestamp.

  CRITICAL PATCH: Uses deep merging to correctly apply partial node updates.
  """

  require Logger
  @table_name :epoch_log_index

  @doc """
  Retrieves the full state of a Node as it existed at `target_time`.
  """
  @spec get_node_state_at_time(String.t(), DateTime.t()) :: {:ok, map()} | {:error, any()} # Returns map as full struct conversion is complex
  def get_node_state_at_time(node_id, target_time) do
    # 1. Find relevant epoch files from Mnesia
    files = find_epoch_files_before(target_time)

    if Enum.empty?(files) do
      {:error, :no_history_found}
    else
      # 2. Reconstruct State
      reconstruct_node(node_id, files, target_time)
    end
  end

  @doc """
  Reconstructs the ENTIRE state of the knowledge graph at a specific point in time.
  Used for Temporal Vector Search.
  """
  @spec get_system_state_at_time(DateTime.t()) :: {:ok, [map()]} | {:error, any()}
  def get_system_state_at_time(target_time) do
    files = find_epoch_files_before(target_time)

    if Enum.empty?(files) do
      {:ok, []} # No history means empty system
    else
      reconstruct_system_state(files, target_time)
    end
  end

  defp find_epoch_files_before(target_time) do
    matcher = :mnesia.transaction(fn ->
      # FIX: Prefixed unused 'id' with underscore
      :mnesia.foldl(fn {_tag, _id, start, _end, path}, acc ->
        if DateTime.compare(start, target_time) != :gt do
          [{start, path} | acc]
        else
          acc
        end
      end, [], @table_name)
    end)

    case matcher do
      {:atomic, result} ->
        # Sort by start_time ascending
        result
        |> Enum.sort_by(fn {start, _} -> start end, DateTime)
        |> Enum.map(fn {_, path} -> path end)
      _ -> []
    end
  end

  defp reconstruct_node(node_id, file_paths, target_time) do
    # Initialize accumulator to nil (meaning node not found yet)
    initial_state = nil

    # Reduce through files (oldest -> newest)
    final_state = Enum.reduce(file_paths, initial_state, fn path, acc_node ->
      if File.exists?(path) do
        File.stream!(path)
        |> Stream.map(&Jason.decode!/1)
        |> Enum.reduce(acc_node, fn entry, curr_node ->
          # Check if this log entry is relevant to our node and time
          if entry["entity"] == "node" and entry["id"] == node_id and Map.has_key?(entry, "data") do
            entry_ts = parse_ts(entry["timestamp"])

            if DateTime.compare(entry_ts, target_time) != :gt do
              apply_event(curr_node, entry)
            else
              curr_node # Skip events after target_time
            end
          else
            curr_node # Skip non-node or non-matching ID entries
          end
        end)
      else
        acc_node # Skip file if not found
      end
    end)

    if final_state do
      Logger.debug("TemporalQueryEngine reconstructed state for #{node_id} at #{DateTime.to_iso8601(target_time)}.")
      {:ok, final_state}
    else
      {:error, :node_not_found_at_timestamp}
    end
  end

  defp reconstruct_system_state(file_paths, target_time) do
    # Accumulator is a Map: %{node_id => node_data}
    final_map =
      Enum.reduce(file_paths, %{}, fn path, acc_system ->
        if File.exists?(path) do
          File.stream!(path)
          |> Stream.map(&Jason.decode!/1)
          |> Enum.reduce(acc_system, fn entry, curr_system ->
            apply_system_event(curr_system, entry, target_time)
          end)
        else
          acc_system
        end
      end)

    {:ok, Map.values(final_map)}
  end

  defp parse_ts(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> dt
      _ -> raise "Invalid timestamp format in epoch log: #{iso_string}"
    end
  end

  # --- New Function: Recursive Deep Map Merge ---
  # FIX: Removed @doc attribute for private function
  defp deep_merge_recursive(v1, v2) when is_map(v1) and is_map(v2) do
    Map.merge(v1, v2, fn _key, val1, val2 -> deep_merge_recursive(val1, val2) end)
  end
  defp deep_merge_recursive(_v1, v2), do: v2
  # ----------------------------------------------


  # Event Application Logic (The "Replay")

  # If it's a creation event, the data is the full node map.
  defp apply_event(_curr, %{"type" => "node_created", "data" => data}), do: data

  # --- LOGIC REFACTOR: Use deep merge for updates/migrations ---
  # If it's an update event, the data is either a delta or a full snapshot.
  # We use deep merge to correctly integrate the data, maintaining fields not present in 'data'.
  defp apply_event(curr, %{"type" => type, "data" => data}) when type in ["node_updated", "node_migrated"] do
    if curr != nil do
      # Deep merge the current state with the incoming update/delta map
      deep_merge_recursive(curr, data)
    else
      Logger.warning("TemporalQueryEngine encountered a #{type} event for non-existent node. Ignoring.")
      curr
    end
  end

  # Ignore other events (like hebbian updates which modify state *during* runtime)
  defp apply_event(curr, _), do: curr

  defp apply_system_event(system_map, %{"entity" => "node"} = entry, target_time) do
    entry_ts = parse_ts(entry["timestamp"])

    # Stop processing if event is in the future relative to target
    if DateTime.compare(entry_ts, target_time) == :gt do
      system_map
    else
      node_id = entry["id"]
      type = entry["type"]
      data = entry["data"]

      case type do
        "node_created" ->
          Map.put(system_map, node_id, data)

        "node_updated" ->
          Map.update(system_map, node_id, data, fn existing ->
             deep_merge_recursive(existing, data)
          end)

        "node_migrated" ->
           Map.update(system_map, node_id, data, fn existing ->
             deep_merge_recursive(existing, data)
           end)

        "node_decayed" ->
           # If decayed/deleted, remove from the snapshot
           Map.delete(system_map, node_id)

        _ -> system_map
      end
    end
  end

  defp apply_system_event(system_map, _, _), do: system_map
  
  # ============================================================================
  # CHRONO-FORENSICS FEATURES
  # ============================================================================
  
  @doc """
  Feature 1: Stack Traversal - Query node history with depth limit.
  
  Returns the last N snapshots from a node's ChronoStack.
  """
  @spec get_node_history(String.t(), keyword()) :: {:ok, [map()]} | {:error, any()}
  def get_node_history(node_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, 10)
    
    # Fetch current node state from Mnesia
    case :mnesia.dirty_read(:nodes_table, node_id) do
      [{_table, _uuid, _hash, _parent, _head, body, _tail, _stack}] ->
        # Extract chrono_stack from body.data_ledger
        chrono_stack = get_in(body, [:data_ledger, :chrono_stack]) || %{snapshots: []}
        snapshots = chrono_stack[:snapshots] || chrono_stack["snapshots"] || []
        
        # Take last N snapshots
        limited_snapshots = Enum.take(snapshots, depth)
        
        # Format snapshots
        formatted = Enum.map(limited_snapshots, fn snapshot ->
          %{
            timestamp: snapshot[:timestamp] || snapshot["timestamp"],
            hash: snapshot[:hash] || snapshot["hash"],
            cause: snapshot[:cause] || snapshot["cause"],
            diff: snapshot[:diff] || snapshot["diff"]
          }
        end)
        
        {:ok, formatted}
      
      [] ->
        {:error, :node_not_found}
    end
  end
  
  @doc """
  Feature 2: Differential Diagnosis - Find all nodes mutated in time range.
  
  Scans all nodes for mutations within the specified time range.
  Returns list of {node_id, path, last_mutation, cause}.
  """
  @spec find_recent_mutations(integer()) :: {:ok, [map()]} | {:error, any()}
  def find_recent_mutations(minutes_ago) do
    cutoff_time = DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)
    
    # Scan all nodes in Mnesia using transaction
    result = :mnesia.transaction(fn ->
      :mnesia.foldl(fn {_table, uuid, _hash, _parent, _head, body, _tail, _stack}, acc ->
        last_mutation = get_in(body, [:data_ledger, :last_mutation])
        
        if last_mutation && DateTime.compare(last_mutation, cutoff_time) == :gt do
          path = get_in(body, [:data_ledger, :physical_symlink]) || "unknown"
          
          # Get mutation cause from chrono_stack
          chrono_stack = get_in(body, [:data_ledger, :chrono_stack]) || %{snapshots: []}
          snapshots = chrono_stack[:snapshots] || chrono_stack["snapshots"] || []
          cause = if length(snapshots) > 0 do
            latest = List.first(snapshots)
            latest[:cause] || latest["cause"] || "unknown"
          else
            "genesis"
          end
          
          mutation = %{
            node_id: uuid,
            path: path,
            last_mutation: last_mutation,
            mutation_cause: cause,
            time_ago: format_time_ago(last_mutation)
          }
          
          [mutation | acc]
        else
          acc
        end
      end, [], :nodes_table)
    end)
    
    case result do
      {:atomic, mutations} ->
        # Sort by most recent first
        sorted = Enum.sort_by(mutations, fn m -> m.last_mutation end, {:desc, DateTime})
        {:ok, sorted}
      {:aborted, reason} ->
        {:error, reason}
    end
  end
  
  @doc """
  Feature 3: Directory State Reconstruction - Virtual view at point in time.
  
  Reconstructs how a directory looked at a specific timestamp.
  """
  @spec reconstruct_directory_state(String.t(), DateTime.t()) :: {:ok, [map()]} | {:error, any()}
  def reconstruct_directory_state(dir_path, target_time) do
    # 1. Find directory node by path
    dir_uuid = UUID.uuid5(:oid, dir_path)
    
    # 2. Get directory's children from epoch logs at that time
    case get_node_state_at_time(dir_uuid, target_time) do
      {:ok, dir_node} ->
        # Extract children from hierarchical edges
        tail = dir_node["tail"] || %{}
        hierarchical = tail["hierarchical"] || []
        
        child_ids = hierarchical
        |> Enum.filter(fn edge -> edge["type"] == "parent_of" end)
        |> Enum.map(fn edge -> edge["target_node_id"] end)
        
        # 3. Reconstruct each child's state at target_time
        children = Enum.map(child_ids, fn child_id ->
          case get_node_state_at_time(child_id, target_time) do
            {:ok, child_node} ->
              %{
                node_id: child_id,
                path: get_in(child_node, ["body", "data_ledger", "physical_symlink"]),
                name: Path.basename(get_in(child_node, ["body", "data_ledger", "physical_symlink"]) || "unknown"),
                mode: get_in(child_node, ["body", "mode"]),
                hash: get_in(child_node, ["body", "data_ledger", "integrity_hash"])
              }
            _ -> nil
          end
        end)
        |> Enum.filter(&(&1 != nil))
        
        {:ok, %{
          directory: dir_path,
          timestamp: target_time,
          children: children,
          count: length(children)
        }}
      
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  # Helper to format time ago
  defp format_time_ago(dt) do
    seconds_ago = DateTime.diff(DateTime.utc_now(), dt, :second)
    cond do
      seconds_ago < 60 -> "#{seconds_ago} seconds ago"
      seconds_ago < 3600 -> "#{div(seconds_ago, 60)} minutes ago"
      seconds_ago < 86400 -> "#{div(seconds_ago, 3600)} hours ago"
      true -> "#{div(seconds_ago, 86400)} days ago"
    end
  end
  
  
end
