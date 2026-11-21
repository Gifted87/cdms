defmodule CMS.Ingestion.CallGraphBinder do
  @moduledoc """
  Production Grade Call Graph Binder (Phase 5).
  
  Resolves cross-file :calls, :imports, and :defines relationships by 
  mapping symbolic placeholders (Ghost Nodes) to concrete execution topology.
  """
  require Logger
  alias CMS.VectorRouter

  @doc """
  Runs the call graph binding pass.
  """
  def run_pass do
    Logger.info("[CallGraphBinder] Initiating Topological Binding Pass...")
    
    ghosts = find_all_ghosts()
    Logger.info("[CallGraphBinder] Identified #{map_size(ghosts)} dangling synaptic anchors.")

    # Build resolution map using the Nominal Index (Symbol Table)
    resolution_map = build_resolution_map(ghosts)
    Logger.info("[CallGraphBinder] Resolved #{map_size(resolution_map)} cross-file relationships.")

    if map_size(resolution_map) > 0 do
      perform_synaptic_forging(resolution_map)
      cleanup_anchors(Map.keys(resolution_map))
      Logger.info("[CallGraphBinder] Call Graph Forged successfully.")
    else
      Logger.info("[CallGraphBinder] No dangling anchors required resolution.")
    end
    
    :ok
  end

  defp find_all_ghosts do
    # Record: {:nodes_table, uuid, hash, parent, head, body, tail, stack, prov, ant}
    spec = [
      {
        {:nodes_table, :"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8", :"$9"},
        [{:==, {:map_get, :width_descriptor, :"$4"}, "ghost"}],
        [{{:"$1", :"$5"}}]
      }
    ]
    
    :mnesia.dirty_select(:nodes_table, spec)
    |> Enum.map(fn {id, body} -> 
      {id, body.data_ledger.physical_symlink}
    end)
    |> Map.new()
  end

  defp build_resolution_map(ghosts) do
    Enum.reduce(ghosts, %{}, fn {ghost_id, symbol}, acc ->
      case resolve_symbol(symbol) do
        {:ok, real_id} when real_id != ghost_id ->
          # Verification: Real node must be a deep or deterministic node, not another ghost
          case :mnesia.dirty_read(:nodes_table, real_id) do
            [{_, ^real_id, _, _, head, _, _, _, _, _}] when head.width_descriptor != "ghost" ->
              Map.put(acc, ghost_id, real_id)
            _ -> acc
          end
        _ -> acc
      end
    end)
  end

  defp resolve_symbol(symbol) do
    # Priority 1: Exact match in Nominal Index
    case VectorRouter.find_by_name(symbol) do
      {:ok, id} -> {:ok, id}
      _ ->
        # Priority 2: Namespace fallback (e.g. B.work -> B)
        case String.split(symbol, ".") do
          parts when length(parts) > 1 ->
            parts |> Enum.drop(-1) |> Enum.join(".") |> VectorRouter.find_by_name()
          _ -> 
            {:error, :not_found}
        end
    end
  end

  defp perform_synaptic_forging(resolution_map) do
    # Batch update edges in the connectome
    all_real_ids = :mnesia.dirty_all_keys(:nodes_table) 
                   |> Enum.filter(fn id -> !Map.has_key?(resolution_map, id) end)

    Enum.each(all_real_ids, fn id ->
      case :mnesia.dirty_read(:nodes_table, id) do
        [record = {:nodes_table, ^id, hash, parent, head, body, tail, stack, prov, ant}] ->
          {new_tail, changed} = update_connectome(tail, resolution_map)
          if changed do
            Logger.debug("[CallGraphBinder] Forging synaptic link for node: #{id}")
            :mnesia.dirty_write({:nodes_table, id, hash, parent, head, body, new_tail, stack, prov, ant})
          end
        _ -> :ok
      end
    end)
  end

  defp update_connectome(tail, resolution_map) do
    {new_func, changed_f} = resolve_edges(tail.functional, resolution_map)
    {new_sync, changed_s} = resolve_edges(tail.syntactic, resolution_map)
    {new_sem, changed_sem} = resolve_edges(tail.semantic, resolution_map)
    
    new_tail = %{tail | functional: new_func, syntactic: new_sync, semantic: new_sem}
    {new_tail, changed_f or changed_s or changed_sem}
  end

  defp resolve_edges(edges, resolution_map) do
    Enum.reduce(edges, {[], false}, fn edge, {acc, changed} ->
      case Map.get(resolution_map, edge.target_node_id) do
        nil -> {[edge | acc], changed}
        real_id -> 
          new_edge = %{edge | target_node_id: real_id}
          {[new_edge | acc], true}
      end
    end)
    |> then(fn {list, changed} -> {Enum.reverse(list), changed} end)
  end

  defp cleanup_anchors(resolved_ids) do
    Enum.each(resolved_ids, fn id ->
      :mnesia.dirty_delete(:nodes_table, id)
    end)
  end
end
