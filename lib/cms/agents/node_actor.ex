defmodule CMS.NodeActor do
  use GenServer
  require Logger

  alias CMS.Node

  @moduledoc """
  The Atomic Unit of Cognition (The Quad-Partite Actor).
  """

  defstruct [:node, :hydrated?, :last_activation_times, :metabolic_energy, :region_id]

  # --- Client API ---

  def fire(uuid) do
    case Registry.lookup(CMS.NodeRegistry, uuid) do
      [{pid, _}] -> GenServer.cast(pid, :fire)
      _ -> {:error, :not_found}
    end
  end

  def pulse(uuid), do: fire(uuid)

  def start_link(%Node{} = node) do
    GenServer.start_link(__MODULE__, node, name: via_tuple(node.id))
  end

  # --- Callbacks ---

  @impl true
  def init(node) do
    # Trap exits to ensure terminate/2 is called for DriftIndex cleanup
    Process.flag(:trap_exit, true)
    
    # Subscribe to the semantic gather bus and query broadcasts
    Phoenix.PubSub.subscribe(CMS.PubSub, "semantic_gather")

    # Pre-compute region_id to avoid O(N) overhead in Scatter-Gather
    region_id = CMS.SemanticRegion.compute_region_hash(node.head.embedding, node.head.embedding_model_version)
    
    # Register with the lock-free index for Scatter-Gather discovery
    CMS.Core.Logic.DriftIndex.register(node.id, node.head.embedding, region_id)

    # Start metabolic decay loop (every 30 seconds)
    Process.send_after(self(), :metabolic_decay, 30_000)

    # We initialize with full energy (1.0).
    {:ok, %__MODULE__{
      node: node, 
      hydrated?: true, 
      last_activation_times: %{}, 
      metabolic_energy: 1.0,
      region_id: region_id
    }}
  end

  @impl true
  def handle_call(:get_state_snapshot, _from, state) do
    {:reply, {:ok, state.node}, state}
  end

  @impl true
  def handle_call(:get_drift_info, _from, state) do
    # Return info needed for drift management
    # Uses cached region_id for extreme performance
    {:reply, {state.node.id, state.node.head.embedding, state.node.head.embedding_model_version, state.region_id}, state}
  end

  @impl true
  def handle_call(:get_trust_score, _from, state) do
    # Provenance usually contains trust_score
    score = Map.get(state.node.provenance || %{}, "trust_score", 0.5)
    {:reply, score, state}
  end

  @impl true
  def handle_call(:recompute_edges, _from, state) do
    # 1. Syntactic Edges (Synchronous AST Parsing)
    new_node = CMS.Core.Logic.EdgeGenerator.generate_edges(state.node)
    
    # 2. Trigger Semantic Scatter-Gather (Asynchronous)
    GenServer.cast(self(), :scatter_gather_edges)
    
    # Persist to both Mnesia and epoch logs
    persist_node(new_node)
    
    {:reply, {:ok, new_node}, %{state | node: new_node}}
  end

  @impl true
  def handle_cast({:update_node, new_node}, state) do
    # Check if this is a Blood node and if we should inhibit persistence
    # We allow persistence only if it's a Bone node OR if it's an authorized pulse.
    # Note: We can check new_node's ChronoStack for the latest cause.
    
    last_cause = List.first(new_node.body.data_ledger.chrono_stack.snapshots || []) 
                |> case do nil -> :unknown; s -> s.cause end

    is_blood = new_node.body.data_ledger.metabolism == :fluid_blood
    is_authorized_pulse = last_cause == :metabolic_pulse
    
    should_persist = not is_blood or is_authorized_pulse
    
    if should_persist do
      # Persistence Strategy: Write-Through Cache
      persist_node(new_node)
    else
      # Just update RAM state, wait for Heartbeat pulse to persist
      Logger.debug("NodeActor: Blood node #{new_node.id} state updated in RAM but inhibited from persistence.")
    end

    {:noreply, %{state | node: new_node}}
  end

  @impl true
  def handle_cast(:scatter_gather_edges, state) do
    # Perform direct scatter-gather to establish semantic edges
    # Now uses the unified EdgeGenerator logic
    new_node = CMS.Core.Logic.EdgeGenerator.generate_semantic_edges(state.node)
    
    if new_node.tail != state.node.tail do
      persist_node(new_node)
      {:noreply, %{state | node: new_node}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_region, _new_region}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:feedback, :irrelevant, target_id, amount}, state) do
    Logger.info("Node #{state.node.id} routing Anti-Hebbian feedback for target #{target_id} (-#{amount})")
    
    # Use sharded buffer for penalization as well (negative delta)
    region_id = CMS.SemanticRegion.compute_region_hash(state.node.head.embedding, state.node.head.embedding_model_version)
    CMS.RegionalHebbianBuffer.buffer_update(state.node.id, [{target_id, -amount}], region_id)
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:add_edge, edge}, state) do
    new_node = %{state.node | tail: CMS.NodeTail.add_edge(state.node.tail, edge)}
    persist_node(new_node)
    {:noreply, %{state | node: new_node}}
  end

  @impl true
  def handle_cast(:fire, state) do
    Logger.info("Node #{state.node.id} is firing!")
    
    now = DateTime.utc_now()
    new_node = %{state.node | last_fired: now}
    
    # Global inhibition still applies
    inhibition = CMS.ActivationEngine.get_global_inhibition_factor()
    
    # Metabolic Modulation: Firing strength depends on energy levels
    # Firing also consumes energy
    firing_cost = 0.2
    energy_modulated_gain = state.node.antenna.gain * state.metabolic_energy
    
    # base_strength modulation by metabolic energy and global inhibition
    # Antenna Gain already incorporates Intrinsic Salience (Salience * 2.0)
    # Modulation Formula: Gain * Energy * Inhibition Factor (0.1 to 1.0)
    base_strength = energy_modulated_gain * inhibition

    # 1. Pulse Semantic, Syntactic, and Hierarchical channels
    # Only semantic pulses trigger Hebbian learning.
    # We EXPLICITLY exclude functional edges to keep the connectome cognitively inert.
    all_edges = state.node.tail.semantic ++ state.node.tail.syntactic ++ state.node.tail.hierarchical
    
    Enum.each(all_edges, fn edge ->
      target_strength = base_strength * edge.weight
      
      Logger.debug(">>> Node #{state.node.id} Propagation: Pulsing target #{edge.target_node_id} [Type: #{edge.type}, Weight: #{edge.weight}, Strength: #{:io_lib.format("~.4f", [target_strength])}]")

      case Registry.lookup(CMS.NodeRegistry, edge.target_node_id) do
        [{pid, _}] -> send(pid, {:activation, state.node.id, target_strength, edge.type})
        _ -> :ok
      end
    end)

    CMS.LogAppender.append_node_event(state.node.id, :node_fired, %{strength: base_strength})
    persist_node(new_node)

    # Post-fire state: Reduced energy
    new_energy = max(0.1, state.metabolic_energy - firing_cost)
    {:noreply, %{state | node: new_node, metabolic_energy: new_energy}}
  end

  @impl true
  def handle_cast({:apply_hebbian_updates, adjustments}, state) do
    new_tail = Enum.reduce(adjustments, state.node.tail, fn {target_id, delta}, acc_tail ->
      update_edge_weight(acc_tail, target_id, delta)
    end)

    if new_tail != state.node.tail do
      Logger.debug("Node #{state.node.id} applied #{length(adjustments)} Hebbian updates in real-time.")
      new_node = %{state.node | tail: new_tail}
      persist_node(new_node)
      {:noreply, %{state | node: new_node}}
    else
      {:noreply, state}
    end
  end

  # --- Internal Helpers moved out of handle_cast block ---

  defp update_edge_weight(tail, target_id, delta) do
    case update_weight_in_list(tail.semantic, target_id, delta) do
      {:ok, new_list} -> %{tail | semantic: new_list}
      :not_found ->
        case update_weight_in_list(tail.syntactic, target_id, delta) do
          {:ok, new_list} -> %{tail | syntactic: new_list}
          :not_found -> tail
        end
    end
  end

  defp update_weight_in_list(list, target_id, delta) do
    case Enum.find_index(list, &(&1.target_node_id == target_id)) do
      nil -> :not_found
      idx ->
        edge = Enum.at(list, idx)
        new_weight = min(1.0, max(0.01, edge.weight + delta))
        {:ok, List.replace_at(list, idx, %{edge | weight: new_weight})}
    end
  end


  @impl true
  def handle_info({:query, query_context}, state) do
    # Decentralized Path: Every node evaluates its own relevance
    case autonomous_query_evaluation(query_context, state) do
      {:fire, relevance} ->
        # 1. Report result to the coordinator
        CMS.QueryCoordinator.node_fired(
          query_context.query_id, 
          state.node.id, 
          relevance, 
          state.node
        )
        
        # 2. Trigger active pulse (Spreading Activation)
        GenServer.cast(self(), :fire)
        
        # Boost metabolic energy on successful hit
        new_energy = min(1.0, state.metabolic_energy + 0.1)
        {:noreply, %{state | metabolic_energy: new_energy}}

      :ignore ->
        # Natural decay of energy if we are ignored?
        # For now, let's keep energy stable unless we fire.
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:semantic_scatter, source_uuid, source_embedding}, state) do
    # AVOID SELF-SIMILARITY
    if source_uuid != state.node.id do
      # Calculate local relevance (Gather)
      # cosine_similarity = (A . B) / (||A|| * ||B||)
      # Nx already handles dot products and normalization if we call it right.
      
      # For simplicity in Phase 1, we use dot product as our embeddings are normalized.
      similarity = Nx.dot(state.node.head.embedding, source_embedding) |> Nx.to_number()

      if similarity > 0.85 do
        Logger.debug("Node #{state.node.id} detected semantic similarity #{:io_lib.format("~.4f", [similarity])} with source #{source_uuid}. Proposing bond.")
        # We are relevant! Propose a bond back to the source via the registry
        case Registry.lookup(CMS.NodeRegistry, source_uuid) do
          [{pid, _}] -> 
            send(pid, {:semantic_proposal, state.node.id, similarity})
          _ -> :ok
        end
      end
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:semantic_proposal, target_id, similarity}, state) do
    # Add the edge to the node's tail
    edge = CMS.Edge.new(target_id, :relates_to, similarity)
    new_node = %{state.node | tail: CMS.NodeTail.add_edge(state.node.tail, edge)}

    # Persist the change to both Mnesia and epoch logs
    persist_node(new_node)

    {:noreply, %{state | node: new_node}}
  end

  @impl true
  def handle_info({:activation, source_id, strength, type}, state) do
    Logger.debug("Node #{state.node.id} received #{type} activation from #{source_id} (strength: #{strength})")

    # threshold logic: only react if strength > inhibitory threshold
    # For now, we use a simple threshold of 0.2
    if strength > 0.2 do
      # --- HIERARCHICAL PATH TRACING ---
      # If a child pulses its parent, the parent must also pulse its parent.
      # This enables 'Breadcrumb Retrieval' during query results.
      if type == :child_of do
        pulse_parent(state.node)
      end

      # Record activation time for Hebbian learning
      now = System.monotonic_time(:millisecond)
      new_activation_times = Map.put(state.last_activation_times, source_id, now)

      # --- NEUROPLASTICITY: SELECTIVE HEBBIAN LEARNING ---
      # Trigger firing if strongly activated (Spatial Summation)
      if strength > 0.7 do
        GenServer.cast(self(), :fire)
        
        # Reward the node that activated us (ONLY if semantic)
        if is_semantic_type?(type) do
          send_hebbian_feedback(source_id, state.node.id)
        end
      end

      # Metabolic Recovery: Activation provides a slight energy boost
      new_energy = min(1.0, state.metabolic_energy + 0.05)

      # Buffer Hebbian update (ONLY if semantic)
      if is_semantic_type?(type) do
        # "Cells that fire together, wire together"
        delta = strength * 0.05
        pseudo_region = :erlang.phash2(source_id, 256)
        CMS.RegionalHebbianBuffer.buffer_update(source_id, [{state.node.id, delta}], pseudo_region)
      end

      {:noreply, %{state | last_activation_times: new_activation_times, metabolic_energy: new_energy}}
    else
      {:noreply, state}
    end
  end

  # Backwards compatibility for untagged activations
  @impl true
  def handle_info({:activation, source_id, strength}, state) do
    handle_info({:activation, source_id, strength, :semantic}, state)
  end

  @impl true
  def handle_info({:pulse, source_id, strength, type}, state) do
    handle_info({:activation, source_id, strength, type}, state)
  end

  @impl true
  def handle_info({:pulse, source_id, strength}, state) do
    handle_info({:activation, source_id, strength, :semantic}, state)
  end

  @impl true
  def handle_info(:delayed_scatter_gather, state) do
    # Triggered after genesis settles - now safe to do scatter-gather
    GenServer.cast(self(), :scatter_gather_edges)
    {:noreply, state}
  end

  @impl true
  def handle_info({:hebbian_reinforce, target_id, amount}, state) do
    Logger.debug("Node #{state.node.id} buffering Hebbian reinforcement for #{target_id} (+#{amount})")
    
    # Route to sharded buffer for aggregation
    region_id = CMS.SemanticRegion.compute_region_hash(state.node.head.embedding, state.node.head.embedding_model_version)
    CMS.RegionalHebbianBuffer.buffer_update(state.node.id, [{target_id, amount}], region_id)
    
    {:noreply, state}
  end

  @impl true
  def handle_info(:metabolic_decay, state) do
    # 3% energy decay every 30s
    new_energy = max(0.2, state.metabolic_energy * 0.97)
    Process.send_after(self(), :metabolic_decay, 30_000)
    {:noreply, %{state | metabolic_energy: new_energy}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp autonomous_query_evaluation(ctx, state) do
    # 1. Semantic Similarity (Dot Product between tensors)
    # Both embedding and query_vector are expected to be Nx tensors
    similarity = Nx.dot(state.node.head.embedding, ctx.query_vector) |> Nx.to_number()

    # 3. Global Inhibition Adjustment (Factor 1.0 -> 0.1)
    inhibition = CMS.ActivationEngine.get_global_inhibition_factor()
    
    # Formula: adjusted_threshold = (base_threshold / max(0.1, inhibition_factor)) * metabolic_cost
    # Metabolic Cost: 1.0 (Full Energy) -> 1.0 multiplier, 0.5 Energy -> 1.2 multiplier
    metabolic_cost = 1.0 + ((1.0 - state.metabolic_energy) * 0.5)

    final_threshold = (ctx.min_relevance / max(0.1, inhibition)) * metabolic_cost

    if similarity >= final_threshold do
      Logger.debug("--- Node #{state.node.id} Decision: RELEVANCE FOUND (#{:io_lib.format("~.4f", [similarity])} >= #{:io_lib.format("~.4f", [final_threshold])}) -> ACTION: FIRING")
      {:fire, similarity}
    else
      if similarity > (final_threshold * 0.5) do
         Logger.debug("--- Node #{state.node.id} Decision: LOW RELEVANCE (#{:io_lib.format("~.4f", [similarity])} < #{:io_lib.format("~.4f", [final_threshold])}) -> ACTION: IGNORED")
      end
      :ignore
    end
  end

  defp persist_node(new_node) do
    try do
      if :mnesia.system_info(:is_running) == :yes and :nodes_table in :mnesia.system_info(:tables) do
        path_hash = UUID.uuid5(:oid, new_node.body.data_ledger.physical_symlink)
        parent_uuid = 
          case Enum.find(new_node.tail.hierarchical, fn e -> e.type == :child_of end) do
            %CMS.Edge{target_node_id: pid} -> pid
            nil -> nil
          end
        stack = new_node.body.data_ledger.chrono_stack
        
        # CRITICAL FIX: Persist to both Mnesia (cache) AND Epoch Logs (source of truth)
        :mnesia.dirty_write({:nodes_table, new_node.id, path_hash, parent_uuid, new_node.head, new_node.body, new_node.tail, stack, new_node.provenance, new_node.antenna})
        
        # Append to epoch log for rehydration capability
        CMS.LogAppender.append_node_event(new_node.id, :node_updated, new_node)
      end
    rescue
      _ -> :ok
    end
  end

  defp send_hebbian_feedback(origin_id, my_id) do
    case Registry.lookup(CMS.NodeRegistry, origin_id) do
       [{pid, _}] -> send(pid, {:hebbian_reinforce, my_id, 0.01})
       _ -> :ok
    end
  end

  defp pulse_parent(node) do
    case Enum.find(node.tail.hierarchical, fn e -> e.type == :child_of end) do
      %CMS.Edge{target_node_id: parent_id, weight: weight} ->
        case Registry.lookup(CMS.NodeRegistry, parent_id) do
          [{pid, _}] -> 
            # High strength pulse to ensure the parent wakes up and propagates
            send(pid, {:activation, node.id, 0.9 * weight, :child_of})
          _ -> :ok
        end
      _ -> :ok
    end
  end

  defp is_semantic_type?(type) do
    type in [:relates_to, :semantic, :contradicts, :supersedes, :superseded_by]
  end

  defp via_tuple(id), do: {:via, Registry, {CMS.NodeRegistry, id}}

  @impl true
  def terminate(_reason, state) do
    CMS.Core.Logic.DriftIndex.unregister(state.node.id)
    :ok
  end
end
