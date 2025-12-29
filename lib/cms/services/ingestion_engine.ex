defmodule CMS.IngestionEngine do
  use GenServer
  require Logger

  alias CMS.{Node, LogAppender, NodeSupervisor, Security, MetaNode, Edge}

  @moduledoc """
  The Gatekeeper. Orchestrates the Zero-Friction Ingestion Protocol.

  Implements:
  - Gap 4: Conflict Detection & Trust-Based Arbitration.
  - Plan Step 7: Automated Association (Hebbian Priming).

  Responsibilities:
  1. Validate incoming data payloads (FIDs).
  2. Enforce Security (ACLs).
  3. Generate Embeddings & Salience Scores.
  4. Detect Conflicts via direct similarity calculation.
  5. Finalize Persistence (Log, Spawn).
  """

  # Configuration
  @min_associative_score 0.3
  @conflict_similarity_threshold 0.8
  @trust_supersede_threshold 0.2 # If new node is > 0.2 more trusted, it wins.


  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Ingests a new atomic thought/fact into the CMS.

  Returns {:ok, node_id} or {:ok, :ingested_with_conflict_resolution, meta_id} or {:error, reason}.
  """
  def ingest(request) do
    # Timeout increased to 30s to allow for Embedding generation and Disk I/O
    GenServer.call(__MODULE__, {:ingest, request}, 30_000)
  end

  # Callbacks

  @impl true
  def init(:ok) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ingest, req}, _from, state) do
    # Step 1: Validation & Security
    with :ok <- validate_payloads(req.description_payloads),
         true <- Security.can_write?(req.agent_id, req.acls || %{read: ["public"], write: ["system"]}) do

      # Step 2: Embedding & Identity Construction
      # We default to the standard model version
      {:ok, embedding} = CMS.Tool.Embedder.generate(req.fact_text, "all-MiniLM-L6-v2")

      node_uuid = CMS.Services.Identity.generate_uuid(req.fact_text) # Use content as path substitute? Or random.
      node_head = CMS.NodeHead.new(node_uuid, embedding, "all-MiniLM-L6-v2")
      data_head = CMS.DataHead.new(req.fact_text)

      # Calculate Salience (Hooked up from SalienceEngine)
      salience = CMS.SalienceEngine.calculate(req.fact_text, req.provenance || %{})

      # *** IMPLEMENTATION: HEBBIAN PRIMING (SCATTER-GATHER) ***
      # Fetch initial associative links *before* creating the DataTail
      # This connects the new node to the existing knowledge graph immediately.
      {:ok, initial_edges} = prime_initial_edges(embedding, "all-MiniLM-L6-v2")

      data_tail = CMS.DataTail.new(req.fact_text, "sha256-placeholder", "text/plain", salience)

      node_body = CMS.NodeBody.new(data_head, req.description_payloads, data_tail)

      # Create Node Struct (ID is derived here via Content Addressability)
      antenna = CMS.NodeAntenna.new(node_uuid)
      new_node = Node.new(node_head, node_body, antenna, req.provenance)
      
      # Attach initial semantic edges
      new_node = %{new_node | tail: %{new_node.tail | semantic: initial_edges}}

      # --- LOGGING: Inspect the DataTail to verify relationships ---
      Logger.info("[Ingestion] Node Created: #{new_node.id} | Relationships: #{length(initial_edges)}")
      Logger.debug("""
      [Ingestion] Constructed DataTail for new fact: "#{String.slice(req.fact_text, 0, 50)}..."
      Relationships: #{length(initial_edges)} found.
      DataTail Dump: #{inspect(data_tail)}
      """)
      # -------------------------------------------------------------

      # Step 3: Conflict Detection & Trust Arbitration (Fix 4)
      # We check if a very similar node already exists (optimized with Scatter-Gather)
      case check_for_conflict(new_node) do
        {:conflict, existing_id} ->
          # Trigger Trust-Based Arbitration
          result = resolve_conflict_with_arbitration(new_node, existing_id)
          {:reply, result, state}

        :ok ->
          # Step 4: Finalize & Activate
          result = finalize_ingestion(new_node)
          {:reply, result, state}
      end

    else
      false -> {:reply, {:error, :permission_denied}, state}
      error -> {:reply, error, state}
    end
  end

  # Internals

  defp validate_payloads(payloads) do
    Enum.reduce_while(payloads, :ok, fn payload, _acc ->
      case CMS.FIDValidator.validate(payload) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  # --- FIX 1: Automated Association / Hebbian Priming Logic (Scatter-Gather) ---
  defp prime_initial_edges(embedding, _model_version) do
    # Use the unified EdgeGenerator logic for Scatter-Gather
    candidates = CMS.Core.Logic.EdgeGenerator.prime_candidates(embedding)

    # --- LOGGING: Relationship Calculation Debug ---
    Logger.info("""
    [Hebbian Priming] Scanned candidates.
    Candidates (score >= #{@min_associative_score}): #{length(candidates)}
    Top Matches: #{inspect(Enum.take(candidates, 3))}
    """)
    # -----------------------------------------------

    edges =
      candidates
      |> Enum.map(fn {target_id, score} ->
        # Use score as the initial weight for the semantic link
        Edge.new(target_id, :semantic, score)
      end)

    {:ok, edges}
  end
  # ------------------------------------------------------------------------


  defp check_for_conflict(new_node) do
    # We can reuse prime_candidates to find high-similarity pairs
    candidates = CMS.Core.Logic.EdgeGenerator.prime_candidates(new_node.head.embedding, new_node.id)
    
    # Conflict check: Look for any candidate >= 0.8
    case Enum.find(candidates, fn {_, score} -> score >= @conflict_similarity_threshold end) do
      {existing_id, _score} ->
        {:conflict, existing_id}
      _ ->
        :ok
    end
  end


  # --- FIX 4: Trust-Based Arbitration & Dialectical Merge ---
  defp resolve_conflict_with_arbitration(new_node, existing_id) do
    Logger.info("Potential conflict detected between New Node #{new_node.id} and Existing #{existing_id}")

    # 1. Fetch Provenance of Existing Node
    existing_trust = get_node_trust_score(existing_id)
    # FIX: Use Map.get safely for provenance as struct definition might vary
    new_provenance = Map.get(new_node, :provenance, %{})
    new_trust = Map.get(new_provenance, "trust_score", 0.5)

    trust_diff = new_trust - existing_trust

    cond do
      # Case A: New node is significantly more trusted -> SUPERSEDE
      trust_diff > @trust_supersede_threshold ->
        Phoenix.PubSub.broadcast(CMS.PubSub, "global:signals",
          {:conflict_resolved, %{type: :superseded, winner: new_node.id, loser: existing_id}}
        )

        handle_supersedence(new_node, existing_id)

      # Case B: Trust is similar or Old node is trusted more -> DIALECTICAL MERGE
      true ->
        Phoenix.PubSub.broadcast(CMS.PubSub, "global:signals",
          {:conflict_resolved, %{type: :dialectical_merge, node_a: new_node.id, node_b: existing_id}}
        )

        handle_dialectical_merge(new_node, existing_id)
    end
  end

  defp get_node_trust_score(node_id) do
    # Attempt to get trust score from active actor
    case NodeSupervisor.get_node_pid(node_id) do
      nil ->
        # Node not active, fetch from history (expensive fallback)
        case CMS.TemporalQueryEngine.get_node_state_at_time(node_id, DateTime.utc_now()) do
          {:ok, node} ->
            prov = Map.get(node, :provenance, %{})
            Map.get(prov, "trust_score", 0.5)
          _ -> 0.5
        end
      pid ->
        # FIX: Explicit GenServer Call to the NodeActor
        try do
          GenServer.call(pid, :get_trust_score, 1000)
        catch
          # If node crashes or times out during arbitration, default to neutral
          :exit, _ -> 0.5
          _, _ -> 0.5
        end
    end
  end

  defp handle_supersedence(new_node, existing_id) do
    Logger.info("Arbitration: New Node #{new_node.id} supersedes #{existing_id} (Trust Diff > #{@trust_supersede_threshold})")

    # 1. Update Existing Node: Mark as superseded
    superseded_edge = Edge.new(new_node.id, :superseded_by, 1.0)

    if pid = NodeSupervisor.get_node_pid(existing_id) do
       GenServer.cast(pid, {:add_edge, superseded_edge})
       # Log the deprecation event
       LogAppender.append_node_event(existing_id, :node_updated, %{reason: "superseded", by: new_node.id})
    end

    # 2. Update New Node: Link back to old (lineage)
    supersedes_edge = Edge.new(existing_id, :supersedes, 1.0)

    updated_tail = CMS.NodeTail.add_edge(new_node.tail, supersedes_edge)
    final_node = %{new_node | tail: updated_tail}

    # 3. Finalize
    finalize_ingestion(final_node)
  end

  defp handle_dialectical_merge(new_node, existing_id) do
    Logger.warning("Arbitration: Ambiguous trust. Initiating Dialectical Merge between #{new_node.id} and #{existing_id}")

    # 1. Spawn MetaNode to document the conflict
    context = %{
      node_a: new_node.id,
      node_b: existing_id,
      reason: "High Semantic Similarity / Content Divergence"
    }
    {:ok, meta_node} = MetaNode.spawn_conflict("Semantic Conflict Detected", context)

    # 2. Modify New Node: Add edges to MetaNode and the Conflicting Node

    # Edge to MetaNode
    edge_to_meta = Edge.new(meta_node.id, :semantic, 0.9)

    # Edge to Conflicting Node (CRITICAL: Explicit Link Typing)
    edge_to_existing = Edge.new(existing_id, :contradicts, 1.0)

    # Filter out the conflicting node if it was accidentally primed as a semantic link
    # Remove any existing edges to the conflicting node from semantic edges
    filtered_semantic = Enum.filter(new_node.tail.semantic, fn edge -> edge.target_node_id != existing_id end)
    
    # Update tail with filtered edges plus new conflict edges
    updated_tail = %{new_node.tail | semantic: [edge_to_meta, edge_to_existing | filtered_semantic]}
    final_node = %{new_node | tail: updated_tail}

    # 3. Finalize MetaNode
    finalize_ingestion(meta_node)

    # Asynchronously update the *existing* node to link back
    if pid = NodeSupervisor.get_node_pid(existing_id) do
      # Edge from existing node to the new node
      GenServer.cast(pid, {:add_edge, Edge.new(final_node.id, :contradicts, 1.0)})
      # Edge from existing node to the meta-node
      GenServer.cast(pid, {:add_edge, Edge.new(meta_node.id, :semantic, 0.9)})
    end

    # Finalize the new conflicting node
    _ = finalize_ingestion(final_node)

    {:ok, :ingested_with_conflict_resolution, meta_node.id}
  end

  defp finalize_ingestion(node) do
    # 1. Persist to Epoch Log (Immutable History)
    LogAppender.append_node_event(node.id, :node_created, node)

    # 2. Spawn NodeActor (Active Memory) - No vector index needed in decentralized model
    case NodeSupervisor.start_child(node) do
      {:ok, _pid} -> {:ok, node.id}
      {:error, {:already_started, _}} -> {:ok, node.id} # Idempotency
      err -> err
    end
  end
end
