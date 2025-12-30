defmodule CMS.NodeActor do
  use GenServer
  require Logger

  alias CMS.Node

  @moduledoc """
  The Atomic Unit of Cognition (The Quad-Partite Actor).
  """

  defstruct [:node, :hydrated?, :last_activation_times, :metabolic_energy, :region_id, :last_query_context]

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
      region_id: region_id,
      last_query_context: nil
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
    # Primary fire (e.g. from query) starts a NEW trace
    trace = MapSet.new([state.node.id])
    ttl = 1
    
    handle_cast({:fire_with_config, trace, ttl}, state)
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

  @impl true
  def handle_cast({:fire_with_config, trace, ttl}, state) do
    Logger.info("Node #{state.node.id} is firing with trace (TTL: #{ttl})!")
    
    now = DateTime.utc_now()
    new_node = %{state.node | last_fired: now}
    
    # Global inhibition still applies
    inhibition = CMS.ActivationEngine.get_global_inhibition_factor()
    
    # Metabolic Modulation - Penalties removed: Energy is always 1.0
    energy_modulated_gain = state.node.antenna.gain # * 1.0
    base_strength = energy_modulated_gain * inhibition

    # Pulse edges with trace and decremented TTL
    all_edges = state.node.tail.semantic ++ state.node.tail.syntactic ++ state.node.tail.hierarchical
    
    edge_count = length(all_edges)
    Logger.info("Node #{state.node.id} preparing to pulse #{edge_count} edges (Base Strength: #{:io_lib.format("~.4f", [base_strength])}, Energy: #{:io_lib.format("~.4f", [state.metabolic_energy])}, Gain: #{state.node.antenna.gain}, Inhibit: #{inhibition})")

    Enum.each(all_edges, fn edge ->
      target_strength = base_strength * edge.weight
      
      Logger.debug(">>> Node #{state.node.id} Propagation: Pulsing target #{edge.target_node_id} [Type: #{edge.type}, Weight: #{edge.weight}, Strength: #{:io_lib.format("~.4f", [target_strength])}, TTL: #{ttl}]")

      case Registry.lookup(CMS.NodeRegistry, edge.target_node_id) do
        [{pid, _}] -> send(pid, {:activation, state.node.id, target_strength, edge.type, trace, ttl})
        [] -> Logger.warning("Node #{state.node.id} failed to pulse #{edge.target_node_id}: Node not found in Registry.")
      end
    end)

    CMS.LogAppender.append_node_event(state.node.id, :node_fired, %{strength: base_strength})
    persist_node(new_node)

    # Post-fire state: Always maintain full energy
    {:noreply, %{state | node: new_node, metabolic_energy: 1.0}}
  end

  # --- Internal Helpers moved TO CMS.Core.Logic.CognitiveMath ---

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
        # REFACTOR: Use Shared Math
        new_weight = CMS.Core.Logic.CognitiveMath.calculate_new_hebbian_weight(edge.weight, delta)
        {:ok, List.replace_at(list, idx, %{edge | weight: new_weight})}
    end
  end


  @impl true
  def handle_info({:query, query_context}, state) do
    if is_directory?(state.node) do
      # Directories are structural, they don't participate in cognitive search
      {:noreply, state}
    else
      # Decentralized Path: Every node evaluates its own relevance
      Logger.info("[QUERY] Node #{String.slice(state.node.id, 0, 8)} evaluating query #{String.slice(query_context.query_id, 0, 8)}...")
    
      case autonomous_query_evaluation(query_context, state) do
        {:fire, relevance} ->
          Logger.info("[FIRE] Node #{String.slice(state.node.id, 0, 8)} FIRES! Relevance: #{:io_lib.format("~.4f", [relevance])} | Path: #{state.node.body.data_ledger.physical_symlink}")
          
          # 1. Report result to the coordinator
          CMS.QueryCoordinator.node_fired(
            query_context.query_id, 
            state.node.id, 
            relevance, 
            state.node
          )
          
          # 2. Trigger active pulse (Spreading Activation)
          GenServer.cast(self(), :fire)
          
          # Always maintain full energy
          {:noreply, %{state | metabolic_energy: 1.0, last_query_context: query_context}}

        {:ignore, relevance, t_adj} ->
          Logger.debug("Node #{String.slice(state.node.id, 0, 8)} ignored: R=#{:io_lib.format("~.4f", [relevance])} < T_adj=#{:io_lib.format("~.4f", [t_adj])}")
          # Still update last_query_context so neighbors can pulse us later
          {:noreply, %{state | last_query_context: query_context}}
      end
    end
  end

  # ... (Semantic Scatter code remains same, handled by EdgeGenerator which uses Nx) ...

  # New activation handler with Trace and TTL loop prevention
  # NEW: Activation handler with Refractory Period Guard
  @impl true
  def handle_info({:activation, source_id, strength, type, trace, ttl}, state) do
    if is_directory?(state.node) do
      # Directories do not participate in Spreading Activation
      {:noreply, state}
    else
      # 1. LOOP PREVENTION: Trace (Stop infinite circles)
      if MapSet.member?(trace, state.node.id) do
        Logger.debug("[TRACE] Node #{String.slice(state.node.id, 0, 8)} already in trace, ignoring activation from #{String.slice(source_id, 0, 8)}")
        {:noreply, state}
      else
        # 2. REFRACTORY GUARD (Stop Multipath Explosion)
        now = DateTime.utc_now()
        last = state.node.last_fired || DateTime.add(now, -3600, :second) 
        diff_ms = DateTime.diff(now, last, :millisecond)

        if diff_ms < 2000 do
          {:noreply, state}
        else
          # 3. TTL LOOP PREVENTION
          if ttl <= 0 do
             Logger.debug("[TTL] Node #{String.slice(state.node.id, 0, 8)} received dead pulse (TTL=0), processing locally only")
             process_activation_locally(source_id, strength, type, state)
          else
             # REFACTOR: Use Shared Math
             boost = CMS.Core.Logic.CognitiveMath.calculate_associative_boost(strength, 1.0, type, :default)

             local_relevance = 
               if state.last_query_context do
                  node_text = state.node.head.label || ""
                  query_text = Map.get(state.last_query_context, :query_text, "")
                  # REFACTOR: Use Shared Math
                  CMS.Core.Logic.CognitiveMath.calculate_relevance_score(state.node.head.embedding, state.last_query_context.query_vector, node_text, query_text)
               else
                  0.0
               end

             total_score = local_relevance + boost
             inhibition = CMS.ActivationEngine.get_global_inhibition_factor()
             # REFACTOR: Use Shared Math
             t_adj = CMS.Core.Logic.CognitiveMath.calculate_adjusted_threshold(get_base_threshold(), inhibition, state.node.head.internal_state)

             if total_score >= t_adj do
                Logger.info("Node #{state.node.id} Firing! (S=#{:io_lib.format("~.4f", [total_score])} > T=#{:io_lib.format("~.4f", [t_adj])})")
                
                new_trace = MapSet.put(trace, state.node.id)
                new_ttl = ttl - 1
                new_node = %{state.node | last_fired: now}
                
                GenServer.cast(self(), {:fire_with_config, new_trace, new_ttl})
                
                if is_semantic_type?(type) do
                  send_hebbian_feedback(source_id, state.node.id)
                  delta = boost * 0.1
                  region_id = CMS.SemanticRegion.compute_region_hash(state.node.head.embedding, state.node.head.embedding_model_version)
                  CMS.RegionalHebbianBuffer.buffer_update(source_id, [{state.node.id, delta}], region_id)
                end

                new_times = Map.put(state.last_activation_times, source_id, System.monotonic_time(:millisecond))
                {:noreply, %{state | node: new_node, last_activation_times: new_times, metabolic_energy: 1.0}}
             else
                {:noreply, state}
             end
          end
        end
      end
    end
  end

  # Backward compatibility: Old activation messages without trace/TTL
  @impl true
  def handle_info({:activation, source_id, strength, type}, state) do
    # Default: empty trace, TTL = 1
    handle_info({:activation, source_id, strength, type, MapSet.new(), 1}, state)
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
    # User Request: "All nodes must be highly active at all times"
    # Instead of decaying, we maintain max energy (1.0)
    new_energy = 1.0
    Process.send_after(self(), :metabolic_decay, 600_000)
    {:noreply, %{state | metabolic_energy: new_energy}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp autonomous_query_evaluation(ctx, state) do
    # 1. Relevance Score ($R$) - Refactored
    node_text = state.node.head.label || ""
    query_text = Map.get(ctx, :query_text, "")
    
    relevance = CMS.Core.Logic.CognitiveMath.calculate_relevance_score(state.node.head.embedding, ctx.query_vector, node_text, query_text)

    # 2. Adjusted Threshold ($T_{adj}$) - Refactored
    base_threshold = get_base_threshold()
    inhibition = CMS.ActivationEngine.get_global_inhibition_factor()
    t_adj = CMS.Core.Logic.CognitiveMath.calculate_adjusted_threshold(base_threshold, inhibition, state.node.head.internal_state)

    if relevance >= t_adj do
      {:fire, relevance}
    else
      {:ignore, relevance, t_adj}
    end
  end

  # --- FORMULAS (DELETED - Moved to Module) ---

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

  # Helper: Process activation locally without propagating (for dead pulses)
  defp process_activation_locally(source_id, strength, type, state) do
    # Calculate boost but don't propagate
    # REFACTOR: Use Shared Math
    boost = CMS.Core.Logic.CognitiveMath.calculate_associative_boost(strength, 1.0, type, :default)
    
    # Local relevance check
    local_relevance = 
      if state.last_query_context do
         node_text = state.node.head.label || ""
         query_text = Map.get(state.last_query_context, :query_text, "")
         # REFACTOR: Use Shared Math
         CMS.Core.Logic.CognitiveMath.calculate_relevance_score(state.node.head.embedding, state.last_query_context.query_vector, node_text, query_text)
      else
         0.0
      end

    total_score = local_relevance + boost

    # Calculate dynamic threshold
    inhibition = CMS.ActivationEngine.get_global_inhibition_factor()
    # REFACTOR: Use Shared Math
    t_adj = CMS.Core.Logic.CognitiveMath.calculate_adjusted_threshold(get_base_threshold(), inhibition, state.node.head.internal_state)

    # If score is high enough, just report to coordinator but don't fire/propagate
    if total_score >= t_adj and state.last_query_context do
      Logger.info("Node #{state.node.id} LOCAL activation (dead pulse): S_total=#{:io_lib.format("~.4f", [total_score])} >= T_adj=#{:io_lib.format("~.4f", [t_adj])}")
      
      # Report to coordinator if in query mode
      CMS.QueryCoordinator.node_fired(
        state.last_query_context.query_id, 
        state.node.id, 
        total_score, 
        state.node
      )
      
      # Hebbian feedback but no propagation
      if is_semantic_type?(type) do
        send_hebbian_feedback(source_id, state.node.id)
      end
      
      new_times = Map.put(state.last_activation_times, source_id, System.monotonic_time(:millisecond))
      {:noreply, %{state | last_activation_times: new_times, metabolic_energy: 1.0}}
    else
      Logger.debug("Node #{state.node.id} IGNORED dead pulse: S_total=#{:io_lib.format("~.4f", [total_score])} < T_adj=#{:io_lib.format("~.4f", [t_adj])}")
      {:noreply, state}
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

  # Helper to fetch threshold dynamically (Defaults to 0.7 if not set)
  defp get_base_threshold do
    Application.get_env(:acn_cms, :node_base_threshold, 0.25)
  end

  defp is_directory?(node) do
    mime = node.body.data_ledger.mime_definition
    type = Map.get(node.provenance || %{}, "type")
    
    mime == "inode/directory" or type == "directory"
  end
end
