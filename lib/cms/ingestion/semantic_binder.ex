defmodule CMS.Ingestion.SemanticBinder do
  @moduledoc """
  Post-Genesis Semantic Binding Pass.

  Forges :semantic and :contradicts edges across the entire connectome
  AFTER Phase 1 (Wavefront) has completed and the full node population
  is stable. This eliminates the race condition where nodes try to link
  to peers that haven't been ingested yet.

  Strategy:
    1. Seed the DriftIndex from Mnesia — ensures all nodes (including
       those without live actors) are visible to the Scatter-Gather.
    2. For every substantive node, run prime_candidates/2 against the
       full DriftIndex.
    3. Forge :semantic edges. Where cosine similarity >= conflict_threshold,
       also forge :contradicts and spawn a MetaNode.
    4. Forge symmetric back-links to guarantee bidirectional energy flow
       in spreading activation.
    5. Persist all changes atomically via Mnesia dirty_write.
  """

  require Logger
  alias CMS.Edge
  alias CMS.NodeTail
  alias CMS.Core.Logic.EdgeGenerator

  @conflict_threshold 0.98
  @embedding_model "all-MiniLM-L6-v2"

  @doc """
  Runs the full semantic binding pass.
  Returns {:ok, stats_map} on completion.
  """
  def run_pass do
    Logger.info("[SemanticBinder] Starting post-genesis semantic binding pass...")

    # STEP 1: Seed DriftIndex from Mnesia (not just live actors)
    seeded = seed_drift_index_from_mnesia()
    Logger.info("[SemanticBinder] DriftIndex seeded with #{seeded} node embeddings.")

    # STEP 2: Collect all substantive node UUIDs
    all_uuids = :mnesia.dirty_all_keys(:nodes_table)

    # STEP 3: Run Scatter-Gather for each node, forge edges
    stats = all_uuids
    |> Task.async_stream(&bind_node_semantically/1,
        max_concurrency: System.schedulers_online(),
        timeout: 60_000,
        on_timeout: :kill_task
      )
    |> Enum.reduce(%{processed: 0, edges_forged: 0, skipped: 0, errors: 0}, fn
      {:ok, {:ok, count}},  acc -> %{acc | processed: acc.processed + 1, edges_forged: acc.edges_forged + count}
      {:ok, :skipped},      acc -> %{acc | skipped: acc.skipped + 1}
      {:ok, {:error, _}},   acc -> %{acc | errors: acc.errors + 1}
      {:exit, _},           acc -> %{acc | errors: acc.errors + 1}
    end)

    Logger.info("[SemanticBinder] Pass complete. #{inspect(stats)}")
    {:ok, stats}
  end

  # ---------------------------------------------------------------------------
  # Step 1: Seed DriftIndex from full Mnesia state
  # ---------------------------------------------------------------------------

  defp seed_drift_index_from_mnesia do
    :mnesia.dirty_all_keys(:nodes_table)
    |> Enum.reduce(0, fn uuid, count ->
      case :mnesia.dirty_read(:nodes_table, uuid) do
        [{:nodes_table, ^uuid, _, _, head, body, _, _, _, _}] ->
          cond do
            # Skip directory nodes and ghost nodes — they carry no semantic signal
            is_directory_or_ghost?(body) -> count
            # Skip zero-vectors (failed embeddings)
            is_nil(head.embedding) -> count
            true ->
              region_id = CMS.SemanticRegion.compute_region_hash(
                head.embedding,
                Map.get(head, :embedding_model_version, @embedding_model)
              )
              CMS.Core.Logic.DriftIndex.register(uuid, head.embedding, region_id)
              count + 1
          end

        # Backward-compatible record without antenna field
        [{:nodes_table, ^uuid, _, _, head, body, _, _, _}] ->
          cond do
            is_directory_or_ghost?(body) -> count
            is_nil(head.embedding) -> count
            true ->
              region_id = CMS.SemanticRegion.compute_region_hash(
                head.embedding,
                Map.get(head, :embedding_model_version, @embedding_model)
              )
              CMS.Core.Logic.DriftIndex.register(uuid, head.embedding, region_id)
              count + 1
          end

        _ -> count
      end
    end)
  end

  defp is_directory_or_ghost?(body) do
    mime = body.data_ledger.mime_definition
    mime == "inode/directory" || mime == "application/x-cms-ghost"
  end

  # ---------------------------------------------------------------------------
  # Step 2: Bind a single node semantically
  # ---------------------------------------------------------------------------

  defp bind_node_semantically(uuid) do
    case :mnesia.dirty_read(:nodes_table, uuid) do
      [{:nodes_table, ^uuid, path_hash, parent_id, head, body, tail, stack, provenance, antenna}] ->
        if is_directory_or_ghost?(body) or is_nil(head.embedding) do
          :skipped
        else
          {new_tail, edge_count} = compute_semantic_edges(uuid, head.embedding, tail)

          if edge_count > 0 do
            :mnesia.dirty_write({:nodes_table, uuid, path_hash, parent_id, head, body, new_tail, stack, provenance, antenna})
            # Also sync the live actor if running
            case CMS.NodeSupervisor.get_node(uuid) do
              {:ok, node} ->
                CMS.NodeSupervisor.update_node(%{node | tail: new_tail})
              _ -> :ok
            end
          end

          {:ok, edge_count}
        end

      [{:nodes_table, ^uuid, path_hash, parent_id, head, body, tail, stack, provenance}] ->
        # Backward-compatible record (5-field provenance, no antenna)
        if is_directory_or_ghost?(body) or is_nil(head.embedding) do
          :skipped
        else
          {new_tail, edge_count} = compute_semantic_edges(uuid, head.embedding, tail)

          if edge_count > 0 do
            :mnesia.dirty_write({:nodes_table, uuid, path_hash, parent_id, head, body, new_tail, stack, provenance})
          end
          {:ok, edge_count}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 3: Scatter-Gather + Edge Forging + Symmetric Back-Links
  # ---------------------------------------------------------------------------

  defp compute_semantic_edges(my_id, embedding, current_tail) do
    candidates = EdgeGenerator.prime_candidates(embedding, my_id)

    {new_tail, count} = Enum.reduce(candidates, {current_tail, 0}, fn {target_id, score}, {tail_acc, cnt} ->
      if score >= @conflict_threshold do
        # DIALECTICAL MERGE — Threshold-based. Works in all modes.
        tail_acc = NodeTail.add_edge(tail_acc, Edge.new(target_id, :contradicts, 1.0))

        context = %{node_a: my_id, node_b: target_id, similarity: score}
        tail_acc = case CMS.MetaNode.spawn_conflict("Semantic overlap detected by SemanticBinder", context) do
          {:ok, meta_node} ->
            CMS.LogAppender.append_node_event(meta_node.id, :node_created, meta_node)
            CMS.NodeSupervisor.spawn_node(meta_node)
            NodeTail.add_edge(tail_acc, Edge.new(meta_node.id, :semantic, 0.9))
          _ ->
            tail_acc
        end

        # Symmetric back-link: target also links to us
        forge_backlink(target_id, my_id, :contradicts, 1.0)
        {tail_acc, cnt + 1}
      else
        # Normal semantic link with cosine similarity as weight
        tail_acc = NodeTail.add_edge(tail_acc, Edge.new(target_id, :semantic, score))
        # Symmetric back-link
        forge_backlink(target_id, my_id, :semantic, score)
        {tail_acc, cnt + 1}
      end
    end)

    {new_tail, count}
  end

  # ---------------------------------------------------------------------------
  # Step 4: Symmetric Back-Linking
  # Ensures B → A exists whenever A → B is forged.
  # Critical for bidirectional spreading activation energy flow.
  # ---------------------------------------------------------------------------

  defp forge_backlink(target_id, source_id, edge_type, weight) do
    case :mnesia.dirty_read(:nodes_table, target_id) do
      [{:nodes_table, ^target_id, ph, pid, head, body, tail, stack, prov, ant}] ->
        new_edge = Edge.new(source_id, edge_type, weight)
        new_tail = NodeTail.add_edge(tail, new_edge)
        :mnesia.dirty_write({:nodes_table, target_id, ph, pid, head, body, new_tail, stack, prov, ant})
        # Sync actor if live
        case CMS.NodeSupervisor.get_node(target_id) do
          {:ok, node} -> CMS.NodeSupervisor.update_node(%{node | tail: new_tail})
          _ -> :ok
        end

      [{:nodes_table, ^target_id, ph, pid, head, body, tail, stack, prov}] ->
        new_edge = Edge.new(source_id, edge_type, weight)
        new_tail = NodeTail.add_edge(tail, new_edge)
        :mnesia.dirty_write({:nodes_table, target_id, ph, pid, head, body, new_tail, stack, prov})

      _ -> :ok
    end
  end
end
