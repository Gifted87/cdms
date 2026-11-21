defmodule CMS.Core.Logic.EdgeGenerator do
  @moduledoc """
  The Edge Generator: Forges the links of the Connectome.
  """

  require Logger
  alias CMS.{Edge, NodeTail}

  @doc """
  Generates all edges for a single node.
  """
  def generate_edges(node, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    skip_semantic = Keyword.get(opts, :skip_semantic, false)
    current_hash = node.body.data_ledger.integrity_hash
    last_hash = node.body.data_ledger.last_linked_hash
    incremental? = Application.get_env(:acn_cms, :incremental_binding, true)

    if not force and incremental? and current_hash == last_hash and last_hash != nil do
      Logger.debug("EdgeGenerator: Skipping already linked node #{node.id}")
      node
    else
      if superficial_node?(node) and not force do
        Logger.debug("EdgeGenerator: Skipping connectome forgery for superficial node #{node.id}")
        node
      else
        Logger.info("EdgeGenerator: Forging connectome for #{node.id}#{if force, do: " [FORCE]", else: ""}")

        structural_edges = CMS.Core.Logic.ConnectomeScanner.scan_skeleton(node)
        immune_edges = CMS.Core.Logic.ConnectomeScanner.scan_immune(node)
        nervous_edges = CMS.Core.Logic.ConnectomeScanner.scan_nervous(node)

        node = node
        |> generate_hierarchical_edges()
        |> generate_syntactic_edges()
        # Semantic edges are deferred to SemanticBinder in Phase 2 during ingestion.
        # They can still be forced here (e.g., from SystemMixer during a manual rebind).
        |> then(fn n -> if skip_semantic, do: n, else: generate_semantic_edges(n) end)

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
    |> mark_as_linked(current_hash)
    end
    end
  end

  defp superficial_node?(node) do
    mime = node.body.data_ledger.mime_definition
    type = Map.get(node.provenance || %{}, "type")
    
    mime == "inode/directory" or type == "directory" or type == "ghost"
  end

  defp mark_as_linked(node, hash) do
    put_in(node.body.data_ledger.last_linked_hash, hash)
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
    if node.body.mode in [:deep, :deterministic] do
      content = CMS.NodeBody.decompress(node.body) || ""
      path = node.body.data_ledger.physical_symlink
      lang = CMS.Ingestion.CodeGraphEngine.language_from_path(path)

      case CMS.Ingestion.CodeGraphEngine.nif_supported?(lang) do
        true ->
          case CMS.Ingestion.CodeGraph.Native.parse_source(lang, content) do
            ast when is_map(ast) ->
              relationships = CMS.Ingestion.CodeGraphEngine.extract_relationships(ast, path)
              forge_edges_from_relationships(node, relationships)
            _ ->
              # Real failure for a supported language
              Logger.warning("EdgeGenerator: NIF failed for #{path} (Language: #{lang}), falling back to regex.")
              legacy_generate_syntactic_edges(node, content, path)
          end
        false ->
          # Silent fallback for unsupported languages (JSON, HTML, etc)
          legacy_generate_syntactic_edges(node, content, path)
      end
    else
      node
    end
  end

  defp forge_edges_from_relationships(node, relationships) do
    Enum.reduce(relationships, node, fn {type, _from, to}, acc ->
      case type do
        "depends_on" -> forge_syntactic_edge(acc, to, :imports)
        "calls"      -> forge_syntactic_edge(acc, to, :calls)
        "defines"    -> forge_syntactic_edge(acc, to, :defines)
        _            -> acc
      end
    end)
  end

  defp forge_syntactic_edge(node, target_name, edge_type) do
    if is_binary(target_name) and is_high_signal?(target_name) do
      case CMS.VectorRouter.find_by_name(target_name) do
        {:ok, target_id} ->
          add_edge_to_node(node, Edge.new(target_id, edge_type, 1.0))
        _ ->
          # Create Ghost Node for unknown symbols
          {ghost_uuid, _ghost_node, mn_record} = CMS.Ingestion.FractalAperture.create_ghost_node(target_name, node.id)
          
          if ghost_uuid != nil do
            case :mnesia.dirty_read(:nodes_table, ghost_uuid) do
              [] -> :mnesia.dirty_write(mn_record)
              _ -> :ok
            end
            
            add_edge_to_node(node, Edge.new(ghost_uuid, edge_type, 1.0))
          else
            node
          end
      end
    else
      node
    end
  end

  # Filter out noise from ghost node creation
  defp is_high_signal?(name) do
    cond do
      # Too short to be a meaningful dependency
      String.length(name) < 3 -> false
      
      # Test library noise (Jest/Vitest)
      String.starts_with?(name, ["expect(", "describe(", "it(", "test(", "beforeEach(", "afterEach("]) -> false
      
      # Common syntactic keywords that slip through some parsers
      name in ~w(IF ELSE WHILE FOR DO RETURN TRY CATCH FINALLY CONST LET VAR) -> false
      
      # Likely a simple variable or property access if it has no dots/slashes
      # but is very common like 'id', 'data', 'item'
      name in ~w(id data item list value key type name) -> false

      true -> true
    end
  end

  defp legacy_generate_syntactic_edges(node, content, path) do
    lang = CMS.Ingestion.CodeGraphEngine.language_from_path(path)
    relationships = CMS.Ingestion.CodeGraphEngine.extract_rigorous_fallback(lang, content, path)
    
    if relationships != [] do
       forge_edges_from_relationships(node, relationships)
    else
       # Fallback to legacy find_imports for remaining types
       imports = find_imports(content, path)
       Enum.reduce(imports, node, fn import_name, acc ->
         forge_syntactic_edge(acc, import_name, :imports)
       end)
    end
  end

  @doc """
  Generates semantic edges using the "Hebbian Priming" Scatter-Gather protocol.
  Queries all active NodeActors in parallel to find semantic neighbors.
  """
  def generate_semantic_edges(node) do
    is_crems = crems_node?(node.id)
    conflict_threshold = if is_crems, do: 0.95, else: 0.98

    my_id = node.id
    candidates = prime_candidates(node.head.embedding, node.id)

    Enum.reduce(candidates, node, fn {target_id, score}, acc ->
      if score >= conflict_threshold and not is_crems do
        # DIALECTICAL MERGE: Threshold-based (not LLM). Works in all modes.
        acc = add_edge_to_node(acc, Edge.new(target_id, :contradicts, 1.0))

        context = %{node_a: my_id, node_b: target_id, similarity: score}
        case CMS.MetaNode.spawn_conflict("Semantic overlap detected during Genesis", context) do
          {:ok, meta_node} ->
             CMS.LogAppender.append_node_event(meta_node.id, :node_created, meta_node)
             CMS.NodeSupervisor.spawn_node(meta_node)
             edge_to_meta = Edge.new(meta_node.id, :semantic, 0.9)
             add_edge_to_node(acc, edge_to_meta)
          _ ->
             acc
        end
      else
        # Normal semantic relationship — weight = raw cosine similarity.
        add_edge_to_node(acc, Edge.new(target_id, :semantic, score))
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
    # Differentiate threshold: 0.9 for CREMS, 0.7 for CDMS
    min_score = if my_id && crems_node?(my_id), do: 0.9, else: 0.7
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
