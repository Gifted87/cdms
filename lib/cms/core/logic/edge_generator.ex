defmodule CMS.Core.Logic.EdgeGenerator do
  @moduledoc """
  The Edge Generator: Forges the links of the Connectome.
  """

  require Logger
  alias CMS.{Edge, NodeTail}

  @doc """
  Generates all edges for a single node.
  """
  def generate_edges(node) do
    # Phase 4 Upgrade: Connectome Scanning
    # We apply this after initial generation phases
    structural_edges = CMS.Core.Logic.ConnectomeScanner.scan_skeleton(node)
    immune_edges = CMS.Core.Logic.ConnectomeScanner.scan_immune(node)
    nervous_edges = CMS.Core.Logic.ConnectomeScanner.scan_nervous(node)
    
    # Merge all edges manually from the previous pipe approach
    # We need to construct the node with valid tails from the previous steps first or just merge results?
    # The previous code piped functions which return 'node'. 
    # But generate_syntactic_edges returns 'node' with updated tail.
    # To correctly integrate, we chain the calls and then inspect/update the final node.
    
    node = node
    |> generate_hierarchical_edges()
    |> generate_syntactic_edges()
    |> generate_semantic_edges()
    
    # Now append Phase 4 edges
    new_tail = node.tail
    
    new_tail = Enum.reduce(structural_edges ++ nervous_edges, new_tail, fn edge, acc ->
      CMS.NodeTail.add_edge(acc, edge)
    end)
    
    # Immune edges might be semantic or own category. Spec calls them Authority.
    # We map them to semantic for generic storage or assume add_edge handles checks.
    # Let's map OWNED_BY/EXECUTABLE_BY to semantic or add support in NodeTail (which defaults generic to syntactic).
    # NodeTail.add_edge handles unknowns by defaulting to syntactic. Spec says Authority Edges.
    # Let's effectively treat them as structural (rigid) or semantic (social)?
    # "Authority Edges describe defense mechanism".
    # Implementation Plan: just add them via standard add_edge.
    
    new_tail = Enum.reduce(immune_edges, new_tail, fn edge, acc ->
      CMS.NodeTail.add_edge(acc, edge)
    end)
    
    %{node | tail: new_tail}
  end

  @doc """
  Generates hierarchical edges (PARENT_OF/CHILD_OF) based on file path.
  Note: This is usually handled during Genesis, but can be re-run.
  """
  def generate_hierarchical_edges(node) do
    # Implementation depends on knowing the directory structure
    # For now, we'll assume the Genesis engine handles this.
    node
  end

  @doc """
  Generates syntactic edges by parsing the file content for imports/dependencies.
  """
  def generate_syntactic_edges(node) do
    if node.body.mode == :deep do
      # Decompress content for analysis
      content = CMS.NodeBody.decompress(node.body) || ""
      path = node.body.data_ledger.physical_symlink
      
      imports = find_imports(content, path)
      
      Enum.reduce(imports, node, fn import_name, acc ->
        # Find node by name
        case CMS.VectorRouter.find_by_name(import_name) do
          {:ok, target_id} ->
            edge = Edge.new(target_id, :imports, 1.0)
            %{acc | tail: NodeTail.add_edge(acc.tail, edge)}
          _ -> 
            # Not found in system. Check if it's a file path to generate a Ghost Node.
            # (Simple heuristic: if it looks like a path or specific system lib)
            if String.contains?(import_name, "/") do
               # Check Bounded Circle
               # NOTE: We need circle_root from node.provenance or opts, but EdgeGenerator 
               # usually runs post-ingest. For Phase 2, we assume we might have circle_root in provenance
               # or just assume specific system paths are external.
               
               # Let's assume for this specific requirement, if we see a path-like import 
               # that isn't in Mnesia, we treat it as external.
               
               {ghost_uuid, _ghost_node, mn_record} = CMS.Ingestion.FractalAperture.create_ghost_node(import_name, node.id)
               
               # Write Ghost to Mnesia (if not exists)
               # Use a safe write or check existence
               case :mnesia.dirty_read(:nodes_table, ghost_uuid) do
                 [] -> :mnesia.dirty_write(mn_record)
                 _ -> :ok
               end
               
               edge = Edge.new(ghost_uuid, :anchored_to, 1.0)
               %{acc | tail: NodeTail.add_edge(acc.tail, edge)}
            else
               acc
            end
        end
      end)
    else
      node
    end
  end

  @doc """
  Generates semantic edges using the "Hebbian Priming" Scatter-Gather protocol.
  Queries all active NodeActors in parallel to find semantic neighbors.
  """
  def generate_semantic_edges(node) do
    # Configuration matches IngestionEngine Spec
    # Differentiate thresholds for CDMS/CREMS
    is_crems = crems_node?(node.id)
    conflict_threshold = if is_crems, do: 0.95, else: 0.8
    
    my_id = node.id

    # Get raw candidates with scores using Scatter-Gather
    candidates = prime_candidates(node.head.embedding, node.id)
    
    Enum.reduce(candidates, node, fn {target_id, score}, acc ->
      if score >= conflict_threshold and not is_crems do
        # --- SPECIAL CASE: DIALECTICAL MERGE ---
        # 1. Add Contradicts Link to Peer
        acc = add_edge_to_node(acc, Edge.new(target_id, :contradicts, 1.0))
        
        # 2. Spawn MetaNode for the conflict
        context = %{node_a: my_id, node_b: target_id, similarity: score}
        case CMS.MetaNode.spawn_conflict("Semantic overlap detected during Genesis", context) do
          {:ok, meta_node} ->
             # Register and spawn MetaNode actor
             CMS.LogAppender.append_node_event(meta_node.id, :node_created, meta_node)
             CMS.NodeSupervisor.spawn_node(meta_node)
             
             # 3. Add Semantic Link to MetaNode
             edge_to_meta = Edge.new(meta_node.id, :semantic, 0.9)
             add_edge_to_node(acc, edge_to_meta)
          _ ->
             acc
        end
      else
        # Normal Semantic Relationship
        edge = Edge.new(target_id, :semantic, score)
        add_edge_to_node(acc, edge)
      end
    end)
  end

  # ... (prime_candidates and cosine_similarity remain) ...

  # --- Helper for Polymorphic Node Support ---

  defp crems_node?(node_id) do
    # CREMS nodes use pid-node-, beam-node-, or mother- prefixes
    String.starts_with?(node_id, ["pid-node-", "beam-node-", "mother-"])
  end

  defp add_edge_to_node(%CMS.Node{} = node, edge) do
    %{node | tail: CMS.NodeTail.add_edge(node.tail, edge)}
  end

  defp add_edge_to_node(%CREMS.Node{} = node, edge) do
    # Map-based Edge Structure for CREMS (Phase 7+)
    # This standardizes CREMS with CDMS for consistency across the Cognitive Graph.
    new_edge = %{
      type: edge.type, 
      target_node_id: edge.target_node_id, 
      weight: edge.weight
    }
    
    # Route to appropriate tail collection based on type
    tail = node.tail
    new_tail = case edge.type do
      t when t in [:parent_of, :child_of] ->
        %{tail | hierarchical_edges: [new_edge | tail.hierarchical_edges]}
      :communicates_with ->
        # Note: communications edges can have extra metadata, but Edge.t() is simplified.
        # NodeActor handles full protocol/ratio via explicit upsert_edge cast.
        %{tail | communication_edges: [new_edge | tail.communication_edges]}
      :depends_on ->
        %{tail | dependency_edges: [new_edge | tail.dependency_edges]}
      t when t in [:semantic, :contradicts, :semantically_related_to] ->
        # Standardize type to :semantically_related_to for CREMS
        standard_edge = %{new_edge | type: :semantically_related_to}
        %{tail | semantic_edges: [standard_edge | tail.semantic_edges]}
      t when t in [:defined_by, :defines] ->
        %{tail | symbiotic_edges: [new_edge | tail.symbiotic_edges]}
      _ ->
        tail
    end
    
    %{node | tail: new_tail}
  end

  @doc """
  Generic Hebbian Priming: Returns a list of semantic candidate pairs {id, score} for a given embedding.
  Queries all active NodeActors in parallel (Scatter-Gather).
  """
  def prime_candidates(embedding, my_id \\ nil) do
    # Configuration matches IngestionEngine Spec
    # Differentiate threshold: 0.9 for CREMS, 0.4 for CDMS
    min_score = if my_id && crems_node?(my_id), do: 0.9, else: 0.4
    max_links = 3
    
    # 1. Fetch all drift info from the lock-free ETS index
    # This eliminates GenServer deadlocks during Scatter-Gather.
    all_drift_info = CMS.Core.Logic.DriftIndex.get_all_drift_info()

    similarities =
      all_drift_info
      |> Enum.reduce([], fn {node_id, remote_embedding, _region_id}, acc ->
        if node_id != my_id and remote_embedding do
           score = cosine_similarity(embedding, remote_embedding)
           if score >= min_score do
             # Logger.debug("EdgeGenerator: Node #{my_id || "NEW"} evaluating #{node_id} -> Score: #{:io_lib.format("~.4f", [score])}")
             [{node_id, score} | acc]
           else
             acc
           end
        else
           acc
        end
      end)

    if length(similarities) > 0 do
       Logger.info("EdgeGenerator: Found #{length(similarities)} semantic candidates for #{my_id || "NEW"} (Min Score: #{min_score})")
    end

    similarities
    |> Enum.sort_by(fn {_, score} -> score end, &>=/2)
    |> Enum.take(max_links)
  end

  @doc """
  Calculates the cosine similarity between two vectors using native Nx operations for maximum performance.
  """
  def cosine_similarity(vec_a, vec_b) do
    try do
      # Directly use tensors if possible, or convert to tensors (much faster than list zip/sum)
      t_a = if is_struct(vec_a, Nx.Tensor), do: vec_a, else: Nx.tensor(vec_a)
      t_b = if is_struct(vec_b, Nx.Tensor), do: vec_b, else: Nx.tensor(vec_b)

      # cosine_similarity = (A . B) / (||A|| * ||B||)
      dot_product = Nx.dot(t_a, t_b) |> Nx.to_number()
      norm_a = Nx.sum(Nx.pow(t_a, 2)) |> Nx.sqrt() |> Nx.to_number()
      norm_b = Nx.sum(Nx.pow(t_b, 2)) |> Nx.sqrt() |> Nx.to_number()

      if norm_a == 0 or norm_b == 0, do: 0.0, else: dot_product / (norm_a * norm_b)
    rescue
      _ -> 0.0
    end
  end

  # --- Import Extraction ---

  defp find_imports(content, path) do
    ext = Path.extname(path)
    cond do
      ext in [".ex", ".exs"] -> 
        find_imports_elixir(content)
      ext == ".py" ->
        # Functional approximation for Python in Phase 1
        (Regex.scan(~r/^import\s+([a-zA-Z0-9_]+)/m, content) |> Enum.map(fn [_, name] -> name end))
        ++ (Regex.scan(~r/^from\s+([a-zA-Z0-9_]+)\s+import/, content) |> Enum.map(fn [_, name] -> name end))
      true ->
        []
    end
  end

  defp find_imports_elixir(content) do
    case Code.string_to_quoted(content) do
      {:ok, quoted} ->
        {_, names} = Macro.prewalk(quoted, [], fn
          {key, _, [{:__aliases__, _, names} | _]}, acc when key in [:alias, :import, :require, :use] ->
             {nil, [Enum.join(names, ".") | acc]}
          node, acc -> {node, acc}
        end)
        Enum.uniq(names)
      _ ->
        []
    end
  end
end
