defmodule CMS.Ingestion.FileIngestionTask do
  @moduledoc """
  The Cognitive Ingestion Pipeline (File Level).
  """

  require Logger
  alias CMS.{Node, NodeHead, NodeBody, NodeTail, NodeAntenna, DataHead, DataTail, Edge}
  alias CMS.Infrastructure.GeminiBridge
  alias CMS.Tool.Embedder # Using the Python Bridge tool
  alias CMS.Ingestion.ExclusionCortex

  # Model Constants
  @embedding_model "all-MiniLM-L6-v2" # Defined in ml_bridge.py

  @doc """
  Ingests a single file into the CDMS.
  """
  def ingest(path, parent_id, spatial_coords \\ {0.0, 0.0, 0}, width_descriptor \\ "m0", opts \\ []) do
    uuid = UUID.uuid5(:oid, path)

    # Step 0: Extract & Check JSON Registry BEFORE any action
    {current_content, current_hash} = read_and_hash(path)
    
    if CMS.Ingestion.NodeRegistry.is_unchanged?(path, current_hash) do
      Logger.info("FileIngestionTask: Found in JSON registry and unchanged, skipping: #{path}")
      
      # Node exists and looks valid. Ensure actor is running.
      case CMS.NodeSupervisor.start_node_from_store(uuid) do
        {:ok, pid} -> CMS.SymbolicIndex.register_path(path, pid)
        _ -> :ok
      end
      {:ok, :skipped, uuid}
    else
      case handle_mnesia_ingest(uuid, path, parent_id, spatial_coords, width_descriptor, opts, current_content, current_hash) do
        {:ok, _id} ->
          # Atomic Registration: Only mark as successful in JSON registry if it didn't crash/fail
          CMS.Ingestion.NodeRegistry.register_node(path, current_hash, uuid)
          # Map to :touched to inform the GenesisCrawler that Phase 2 is required
          {:ok, :touched, uuid}
        error -> 
          error
      end
    end
  end

  defp handle_mnesia_ingest(uuid, path, parent_id, spatial_coords, width_descriptor, opts, content, hash) do
    # Idempotency Check: See if node already exists in Mnesia
    case :mnesia.dirty_read(:nodes_table, uuid) do
      [{:nodes_table, ^uuid, _hash, _parent, _head, %{data_head: %{summary: "Processing failed" <> _}}, _tail, _stack, _provenance, _antenna}] ->
        # Existing node found but it was a failure. Re-ingest.
        Logger.info("FileIngestionTask: Re-ingesting previously failed node: #{path}")
        do_ingest(uuid, path, parent_id, spatial_coords, width_descriptor, opts, content, hash)

      [{:nodes_table, ^uuid, _hash, _parent, _head, body, _tail, _stack, _provenance, _antenna}] ->
        stored_hash = case body do
          %{data_ledger: %{integrity_hash: h}} -> h
          _ -> nil
        end
        
        if hash != stored_hash do
          Logger.info("FileIngestionTask: Drift detected for #{path}. Remodeling...")
          # Delete old node from mnesia before re-ingesting to avoid conflicts
          :mnesia.dirty_delete(:nodes_table, uuid)
          do_ingest(uuid, path, parent_id, spatial_coords, width_descriptor, opts, content, hash)
        else
          case CMS.NodeSupervisor.start_node_from_store(uuid) do
            {:ok, pid} -> CMS.SymbolicIndex.register_path(path, pid)
            _ -> :ok
          end
          {:ok, uuid}
        end

      [] ->
        do_ingest(uuid, path, parent_id, spatial_coords, width_descriptor, opts, content, hash)
    end
  end

  defp do_ingest(_uuid, path, parent_id, spatial_coords, width_descriptor, opts, content, hash) do
        Logger.info("Cognitive Ingestion Task: Starting for #{path}")
        edge_generation = Keyword.get(opts, :edge_generation, true)

        # Step 1: Physical Assessment & Decision Gate
        case ExclusionCortex.assess_file(path) do
          {:ok, assessed_mode, _reason} ->
            mode = Keyword.get(opts, :cognitive_mode, assessed_mode)
            provenance = Keyword.get(opts, :provenance, %{"source" => "local_ingestion"})
            process_file(path, parent_id, mode, spatial_coords, width_descriptor, edge_generation, provenance, content, hash)

          {:error, reason} ->
            Logger.error("Failed to assess file #{path}: #{inspect(reason)}")
            {:error, reason}
        end
    end

  defp process_file(path, parent_id, mode, spatial_coords, width_descriptor, edge_generation, provenance, content, hash) do
    mime = detect_mime(path)

    # Step 3: The Cognitive Request (Gemini - Inference)
    case run_cognitive_step(path, content, mime, mode) do
      {:ok, {summary, concepts}} ->
        continue_ingestion(path, parent_id, mode, spatial_coords, width_descriptor, edge_generation, content, hash, mime, summary, concepts, provenance)
      
      {:error, :llm_failure} when mode != :deterministic ->
        Logger.warning("Ingestion FALLBACK for #{path}: LLM resource exhausted after retries. Using deterministic mode.")
        
        # Re-run with deterministic fallback
        new_mode = :deterministic
        new_provenance = Map.put(provenance, "fallback", true)
        {:ok, {summary, concepts}} = run_cognitive_step(path, content, mime, new_mode)
        
        continue_ingestion(path, parent_id, new_mode, spatial_coords, width_descriptor, edge_generation, content, hash, mime, summary, concepts, new_provenance)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_cognitive_step(path, content, mime, mode) do
    cond do
      mode == :deterministic ->
        # Use Deterministic Aggregator (Dimension 1-5)
        summary = CMS.Ingestion.DeterministicAggregator.aggregate(path, content, mime)
        # In deterministic mode, we can extract keywords as concepts
        concepts = summary 
                   |> String.split("[KEYWORDS]: ") 
                   |> List.last() 
                   |> String.split("\n") 
                   |> List.first() 
                   |> String.split(", ")
        {:ok, {summary, concepts}}

      mode == :mode_a_deep ->
        summary_result = GeminiBridge.summarize(content, "gemini-2.5-flash-lite", path)
        
        case summary_result do
          {:ok, %{"summary" => s, "concepts" => c}} ->
            case ExclusionCortex.validate_cognition(s) do
              :ok -> {:ok, {s, c}}
              {:error, gate_reason} -> 
                Logger.error("Ingestion ABORTED for #{path}: Semantic Gate failure (#{gate_reason})")
                {:error, :semantic_gate_failure}
            end
          {:error, llm_reason} -> 
            Logger.error("Ingestion ABORTED for #{path}: LLM error (#{inspect(llm_reason)})")
            {:error, :llm_failure}
        end

      true ->
        {:ok, {"Shallow representation of binary or large file.", []}}
    end
  end

  defp continue_ingestion(path, parent_id, mode, spatial_coords, width_descriptor, edge_generation, content, hash, mime, summary, concepts, provenance) do

    # -- PATCH: Sanitize Inputs --
    content = if String.valid?(content), do: content, else: "[BINARY OMITTED]"
    summary = if String.valid?(summary), do: summary, else: "[BINARY OMITTED]"
    # ----------------------------
    # -- UTF-8 SANITIZATION PATCH --
    safe_content = if String.valid?(content), do: content, else: "[BINARY CONTENT OMITTED]"
    # ------------------------------
    

    # Step 4: Vectorization (Python ML Bridge)
    # Uses CMS.Tool.Embedder.generate
    vector_input = """
    FILE: #{Path.basename(path)}
    SUMMARY: #{summary}
    CONTENT:
    #{safe_content}
    """
    
    # Defaults to all-MiniLM-L6-v2 in ml_bridge.py
    embedding = case Embedder.generate(vector_input, @embedding_model) do
      {:ok, tensor} -> 
         tensor
      {:error, reason} ->
         Logger.warning("Embedding failed for #{path}: #{inspect(reason)}. Using zero-vector.")
         Nx.broadcast(Nx.tensor(0.0), {384})
    end

    # Step 5: Salience & Antenna Tuning
    geography = CMS.Ingestion.FractalAperture.analyze_geography(path)
    base_salience = CMS.SalienceEngine.calculate(summary, provenance, mode: mode)
    salience = CMS.Ingestion.FractalAperture.adjust_salience(base_salience, geography)
    
    antenna = NodeAntenna.new(path, salience)
    
    # Optional logic: If gate failed, dampen significantly regardless of content
    antenna = if summary == "Processing failed (Semantic Gate)", do: %{antenna | gain: 0.1, salience: 0.05}, else: antenna

    # Step 6: Identify & Pre-Register (Required for Edge Resolution)
    uuid = UUID.uuid5(:oid, path)
    filename = Path.basename(path)
    stem = Path.rootname(filename)

    CMS.VectorRouter.register_name(filename, uuid)
    CMS.VectorRouter.register_name(stem, uuid)
    
    # Register Module Names for Syntactic Resolution
    if Path.extname(path) in [".ex", ".exs"] do
      case Code.string_to_quoted(content) do
        {:ok, quoted} ->
          Macro.prewalk(quoted, fn
            {:defmodule, _, [{:__aliases__, _, names} | _]} ->
              CMS.VectorRouter.register_name(Enum.join(names, "."), uuid)
              nil
            other -> other
          end)
        _ -> :ok
      end
    end

    # Add to HNSW Index immediately so semantic search can find it
    CMS.VectorRouter.add_embedding(uuid, embedding, @embedding_model)

    # Step 7: Struct Construction
    head = NodeHead.new(uuid, embedding, @embedding_model, 0.35, spatial_coords, width_descriptor)
    data_head = DataHead.new(summary, concepts)
    
    # Anatomy Engine Integration
    # 1. Classify Organ
    triage_class = CMS.Ingestion.TriageProtocol.identify(path) |> case do {:ok, c} -> c; _ -> :unknown end
    _organ_type = CMS.Ingestion.AnatomyEngine.classify_organ(triage_class, path, mime) # Store this if needed in provenance?
    
    # 2. Extract Essence (Ledger Data)
    essence = CMS.Ingestion.AnatomyEngine.extract_essence(path)
    
    # 3. Classify Metabolism
    metabolism = CMS.Ingestion.AnatomyEngine.classify_metabolism(path, triage_class)
    
    # Create DataTail with full Anatomical Ledger
    data_ledger = DataTail.new(path, hash, mime, salience, essence.permissions, essence.ownership, essence.immutable_flags, essence.genetic_provenance, metabolism)
    
    body = NodeBody.new(data_head, if(mode in [:mode_a_deep, :deterministic], do: content, else: nil), data_ledger, if(mode == :mode_a_deep, do: :deep, else: :shallow))
    
    node = Node.new(head, body, antenna, provenance)

    # Add link to parent
    node = if parent_id do
      edge = Edge.new(parent_id, :child_of, 1.0)
      %{node | tail: NodeTail.add_edge(node.tail, edge)}
    else
      node
    end

    # Step 8: Edge Forging (Now with registration data available)
    node = if edge_generation do
      CMS.Core.Logic.EdgeGenerator.generate_edges(node)
    else
      node
    end
    
    # Step 9: Mnesia Persistence
    path_hash = UUID.uuid5(:oid, path)
    
    :mnesia.dirty_write({:nodes_table, uuid, path_hash, parent_id, node.head, node.body, node.tail, CMS.ChronoStack.new(), node.provenance, node.antenna})

    # Append to epoch log for rehydration capability
    CMS.LogAppender.append_node_event(uuid, :node_created, node)

    # Step 10: Spawn Actor
    case CMS.NodeSupervisor.spawn_node(node) do
      {:ok, pid} -> 
        CMS.SymbolicIndex.register_path(path, pid)
        
        # Phase 2 (Binding) now handles global connectivity in a synchronized pass.
        # Removing delayed tasks to prevent "reforging" noise and race conditions.
        
        CMS.Services.LiveWire.watch(path)
        
        Logger.info("Successfully ingested node: #{uuid} (#{Path.basename(path)})")
        {:ok, uuid}
      error ->
        Logger.error("Failed to spawn node for #{path}: #{inspect(error)}")
        error
    end
  end

  # --- Helpers ---

  defp read_and_hash(path) do
    content = safe_read(path, 3)
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    {content, hash}
  end

  defp safe_read(path, retries) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, reason} when retries > 0 ->
        jitter = :rand.uniform(100)
        Logger.warning("File locked or busy: #{path} (#{inspect(reason)}). Retrying in #{100 + jitter}ms... (#{retries} left)")
        :timer.sleep(100 + jitter)
        safe_read(path, retries - 1)
      {:error, reason} ->
        Logger.error("Failed to read file after retries: #{path} (#{inspect(reason)})")
        raise "File access failure: #{path}"
    end
  end

  defp detect_mime(path) do
    case Path.extname(path) do
      ".ex" -> "text/x-elixir"
      ".exs" -> "text/x-elixir"
      ".py" -> "text/x-python"
      ".js" -> "application/javascript"
      ".md" -> "text/markdown"
      _ -> "application/octet-stream"
    end
  end
end
