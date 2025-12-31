defmodule CREMS.Agents.NodeActor do
  use GenServer
  require Logger

  alias CREMS.Node
  alias CMS.Core.Logic.CognitiveMath
  alias CREMS.Physics.PhantomManifold

  @moduledoc """
  The Volatile Runtime Actor for CREMS.
  
  Behavior:
  - Ephemeral (Does not persist to disk, only Mnesia RAM).
  - Uses shared cognitive logic (CMS.Core.Logic.CognitiveMath) for relevance and activation.
  - Updates physiological state (Satisfaction) based on telemetry.
  """

  defstruct [:node, :last_activation_times, :metabolic_energy, :region_id, :last_query_context, :ghost_metadata]

  # --- Client API ---

  def start_link(%Node{} = node) do
    GenServer.start_link(__MODULE__, node, name: via_tuple(node.id))
  end

  def pulse(uuid) do
    case Registry.lookup(CMS.NodeRegistry, uuid) do
      [{pid, _}] -> GenServer.cast(pid, :fire)
      _ -> {:error, :not_found}
    end
  end

  # --- Callbacks ---

  @impl true
  def init(node) do
    # 1. Subscribe to Semantic Bus
    Phoenix.PubSub.subscribe(CMS.PubSub, "semantic_gather")

    # 2. Register for Drift Index
    region_id = CMS.SemanticRegion.compute_region_hash(node.head.embedding, "all-MiniLM-L6-v2")
    CMS.Core.Logic.DriftIndex.register(node.id, node.head.embedding, region_id)

    # 3. Perform HEBBIAN PRIMING (Wiring)
    # "Must use the exact wiring logic as the CDMS"
    # We call the EdgeGenerator, which now supports CREMS nodes via polymorphism.
    wired_node = CMS.Core.Logic.EdgeGenerator.generate_semantic_edges(node)
    
    # Log the wiring result
    edge_count = length(wired_node.tail.semantic_edges)
    Logger.info("CREMS Node #{node.id} booted & wired. Region: #{region_id}. Edges: #{edge_count}")

    {:ok, %__MODULE__{
      node: wired_node,
      last_activation_times: %{},
      metabolic_energy: 1.0,
      region_id: region_id,
      last_query_context: nil,
      ghost_metadata: nil
    }}
  end

  # --- Calls ---

  @impl true
  def handle_call(:get_state_snapshot, _from, state) do
    {:reply, {:ok, state.node}, state}
  end

  # --- Calls ---

  @impl true
  def handle_call(:get_phantom_snapshot, _from, state) do
     # Return lightweight snapshot for simulation
     snapshot = %{
       id: state.node.id,
       body: state.node.body,
       tail: state.node.tail
     }
     {:reply, snapshot, state}
  end

  # --- Casts ---

  # Ghost mode check: Ghosts don't fire
  @impl true
  def handle_cast(:fire, %{ghost_metadata: %{is_ghost: true}} = state) do
     Logger.debug("[NodeActor] Ghost node #{state.node.id} ignoring activation (dead)")
     {:noreply, state}
  end

  @impl true
  def handle_cast(:fire, state) do
    # Primary fire starts a NEW trace
    trace = MapSet.new([state.node.id])
    ttl = 2 # Default TTL for CREMS
    handle_cast({:fire_with_config, trace, ttl}, state)
  end

  @impl true
  def handle_cast({:fire_with_config, trace, ttl}, state) do
    Logger.info("[CREMS] Node #{state.node.id} firing with trace (TTL: #{ttl})")
    
    # 1. Decay TTL
    if ttl > 0 do
       # 2. Get Edges
       # CREMS nodes usually have edges in 'tail'.
       all_edges = state.node.tail.semantic_edges ++ state.node.tail.hierarchical_edges 
       # + tail.syntactic if exists (it doesn't in CREMS)
       
       # 3. Strength Calculation (Shared Math)
       inhibition = CMS.ActivationEngine.get_global_inhibition_factor()
       base_strength = state.node.antenna.gain * inhibition
       
       # 4. Propagate
       Enum.each(all_edges, fn edge ->
         target_strength = base_strength * edge.weight 
         case Registry.lookup(CMS.NodeRegistry, edge.target_node_id) do
            [{pid, _}] -> 
               send(pid, {:activation, state.node.id, target_strength, edge.type, trace, ttl - 1})
            [] -> :ok
         end
       end)
    end
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_physics, feelings, raw_stats}, state) do
     # 1. Update Volatile history for rate-of-change calc
     # (This is separate from the ChronoStack which is for Significant transitions)
     current_stack = state.node.body.data_tail.chrono_stack.head_layer[:history] || []
     new_history = [feelings | Enum.take(current_stack, 9)]
     
     # 2. Simulate (Phantom Manifold Predictions)
     model = state.node.body.fid_physics_model
     
     # Use current strain as the load proxy for saturation prediction (Spec 7.2)
     current_saturation = PhantomManifold.predict_saturation(feelings.strain, model)
     
     # 3. Update Body & Model
     body = state.node.body
     
     # Sentinel Updates: Directly update the mutable head_layer (Spec 7.1)
     new_chrono_stack = CREMS.ChronoStack.update_head(body.data_tail.chrono_stack, %{
        state: feelings.state,
        stress: feelings.stress,
        strain: feelings.strain,
        agility: feelings.agility,
        satisfaction: feelings.satisfaction,
        saturation: current_saturation, 
        telemetry: raw_stats,
        history: new_history
     })
     
     new_data_tail = %{body.data_tail | chrono_stack: new_chrono_stack}

     new_body = %{body | 
        fid_state: feelings.state,
        fid_stress: feelings.stress,
        fid_strain: feelings.strain,
        fid_agility: feelings.agility,
        fid_satisfaction: feelings.satisfaction,
        fid_telemetry: raw_stats,
        fid_effect: feelings.effect,
        data_tail: new_data_tail
     }

     new_node = %{state.node | body: new_body}
     
     # Log significant stress - Antennal Boost is triggered by distinct cast from Sentinel, 
     # but we log Backpressure here.
     if current_saturation > 1.0 do
        Logger.warning("[BACKPRESSURE] Node #{state.node.id} Oversaturated (Sat=#{Float.round(current_saturation, 2)}).")
     end

     persist_node(new_node)
     {:noreply, %{state | node: new_node}}
  end

  @impl true
  def handle_cast({:boost_antenna, multiplier}, state) do
     current_gain = state.node.antenna.gain
     new_gain = min(5.0, current_gain * multiplier) # Cap max gain
     
     new_antenna = %{state.node.antenna | gain: new_gain}
     new_node = %{state.node | antenna: new_antenna}
     
     Logger.info("[ADAPTATION] Node #{state.node.id} boosting antenna gain to #{new_gain}")
     
     {:noreply, %{state | node: new_node}}
  end

  @impl true
  def handle_cast({:upsert_edge, type, target_id, metadata}, state) do
     case type do
        :communicates_with ->
          edges = state.node.tail.communication_edges || []
          ratio = Map.get(metadata, :ratio, 1.0)
          proto = Map.get(metadata, :proto, :tcp)
          
          new_edge = %{type: :communicates_with, target_node_id: target_id, protocol: proto, ratio: ratio}
          
          # Robustness logic: handle both Maps (new) and Tuples (legacy)
          new_edges = [new_edge | Enum.reject(edges, fn
            %{target_node_id: t} -> t == target_id
            {:communicates_with, t, _, _} -> t == target_id
            _ -> false
          end)]
            
          new_tail = %{state.node.tail | communication_edges: new_edges}
          new_node = %{state.node | tail: new_tail}
          persist_node(new_node)
          {:noreply, %{state | node: new_node}}

       :child_of ->
         # Hierarchy edges in CREMS are usually in head or tail depending on preference.
         # Spec says: "Creates :child_of edge".
         edges = state.node.tail.hierarchical_edges || []
         new_edges = [%{type: :child_of, target_node_id: target_id, weight: 1.0} | 
                      Enum.reject(edges, &(&1.target_node_id == target_id))]
         
         new_tail = %{state.node.tail | hierarchical_edges: new_edges}
         new_node = %{state.node | tail: new_tail}
         persist_node(new_node)
         {:noreply, %{state | node: new_node}}

       :depends_on ->
         # Spec says: "Creates :depends_on edges".
         edges = state.node.tail.dependency_edges || []
         new_edges = [%{type: :depends_on, target_node_id: target_id, weight: 0.8} | 
                      Enum.reject(edges, &(&1.target_node_id == target_id))]
         
         new_tail = %{state.node.tail | dependency_edges: new_edges}
         new_node = %{state.node | tail: new_tail}
         persist_node(new_node)
         {:noreply, %{state | node: new_node}}

        :semantically_related_to ->
          # Support for semantic edge updates
          edges = state.node.tail.semantic_edges || []
          weight = Map.get(metadata, :score, 0.5)
          new_edge = %{type: :semantically_related_to, target_node_id: target_id, weight: weight}
          
          # Robustness: reject existing by ID, handling both map and tuple formats
          new_edges = [new_edge | Enum.reject(edges, fn
            %{target_node_id: t} -> t == target_id
            {:semantically_related_to, t, _} -> t == target_id
            _ -> false
          end)]
          
          new_tail = %{state.node.tail | semantic_edges: new_edges}
         new_node = %{state.node | tail: new_tail}
         persist_node(new_node)
         {:noreply, %{state | node: new_node}}

         :defined_by ->
           # Bridge edge to CDMS
           edges = state.node.tail.symbiotic_edges || []
           new_edge = %{type: :defined_by, target_node_id: target_id, weight: 1.0}
           
           new_edges = [new_edge | Enum.reject(edges, fn
             %{target_node_id: t} -> t == target_id
             {:defined_by, t} -> t == target_id
             {:defines, t} -> t == target_id
             _ -> false
           end)]
          
          new_tail = %{state.node.tail | symbiotic_edges: new_edges}
          new_node = %{state.node | tail: new_tail}
          persist_node(new_node)
          {:noreply, %{state | node: new_node}}

       _ ->
         Logger.warning("[NodeActor] Unhandled edge type: #{type}")
         {:noreply, state}
     end
  end

  @impl true
  def handle_cast({:push_history, snapshot_data}, state) do
     # Evolve: Push current head_layer to stack_layers. Update head_layer with new reality.
     # (Ref: Spec 7.2 Evolve)
     new_stack = CREMS.ChronoStack.evolve(state.node.body.data_tail.chrono_stack, snapshot_data)
     
     new_data_tail = %{state.node.body.data_tail | chrono_stack: new_stack}
     new_body = %{state.node.body | data_tail: new_data_tail}
     new_node = %{state.node | body: new_body}
     
     persist_node(new_node)
     {:noreply, %{state | node: new_node}}
  end

  @impl true
  def handle_cast({:update_model_constants, constants}, state) do
     elasticity = Map.get(constants, :elasticity_coefficient, 1.0)
     saturation = Map.get(constants, :saturation_point, 1.0)
     
     new_model = %{state.node.body.fid_physics_model | 
        elasticity_coefficient: elasticity, 
        saturation_point: saturation
     }
     new_body = %{state.node.body | fid_physics_model: new_model}
     new_node = %{state.node | body: new_body}
     
     persist_node(new_node)
     {:noreply, %{state | node: new_node}}
  end

  # Keep alias for backward compatibility or direct sentinel calls
  @impl true
  def handle_cast({:update_communication_edge, target_id, ratio}, state) do
     handle_cast({:upsert_edge, :communicates_with, target_id, %{ratio: ratio}}, state)
  end

  # --- Ghost Mode (Section 8.3) ---

  @impl true
  def handle_cast({:enter_ghost_mode, exit_code, _final_snapshot, retention_expiry}, state) do
     Logger.warning("[NodeActor] GHOST TRANSITION: Node #{state.node.id} entering Ghost Mode. Exit: #{exit_code}, Expiry: #{retention_expiry}")
     
     # Section 8.3: Ghost Transition
     # The CREMS.Node actor does not die. It enters Ghost Mode.
     
     # 1. Generate Forensic Natural Language Fact
     death_time = DateTime.utc_now()
     exit_reason = interpret_exit_code(exit_code)
     death_classification = if exit_code == 0, do: "terminated gracefully", else: "crashed"
     
     original_fact = state.node.body.natural_language_fact
     forensic_fact = "DECEASED: #{original_fact} | Death: #{death_classification} (exit code #{exit_code} - #{exit_reason}) at #{DateTime.to_iso8601(death_time)}. Available for forensic analysis until #{DateTime.to_iso8601(retention_expiry)}."
     
     # 2. Generate new embedding for forensic discoverability
     new_embedding = 
       case CMS.Tool.Embedder.generate(forensic_fact, "all-MiniLM-L6-v2") do
         {:ok, tensor} -> tensor
         {:error, reason} ->
           Logger.error("[NodeActor] Failed to re-embed ghost node: #{inspect(reason)}")
           state.node.head.embedding  # Fallback to original
       end
     
     # 3. Add forensic tags
     forensic_tags = generate_forensic_tags(exit_code, death_classification)
     new_tags = (state.node.body.semantic_tags || []) ++ forensic_tags |> Enum.uniq()
     
     # 4. Update Node with forensic context
     new_head = %{state.node.head | embedding: new_embedding}
     new_body = %{state.node.body | 
       natural_language_fact: forensic_fact,
       semantic_tags: new_tags
     }
     new_node = %{state.node | head: new_head, body: new_body}
     
     # 5. Persist forensic node state
     persist_node(new_node)
     
     # 5.5 Update DriftIndex for semantic consistency (Discovery)
     CMS.Core.Logic.DriftIndex.register(state.node.id, new_embedding, state.region_id)
     
     # 6. Ghost Metadata
     ghost_metadata = %{
       is_ghost: true,
       death_time: death_time,
       retention_expiry: retention_expiry,
       exit_code: exit_code
     }
     
     # 7. Low Memory Footprint: Clear large volatile buffers
     cleared_state = %{state |
       node: new_node,
       last_activation_times: %{},
       metabolic_energy: 0.0,  # No longer metabolically active
       last_query_context: nil,
       ghost_metadata: ghost_metadata
     }
     
     Logger.info("[NodeActor] Ghost Mode active. Node #{state.node.id} re-embedded with forensic context. Queryable until #{retention_expiry}")
     {:noreply, cleared_state}
  end
  
   @impl true
  def handle_cast({:update_death_state, updates}, state) do
     # Update node body with death-related state
     new_body = %{state.node.body |
       fid_state: Map.get(updates, :fid_state, state.node.body.fid_state),
       fid_satisfaction: Map.get(updates, :fid_satisfaction, state.node.body.fid_satisfaction),
       fid_output: Map.get(updates, :fid_output, state.node.body.fid_output)
     }
     
     new_node = %{state.node | body: new_body}
     persist_node(new_node)
     {:noreply, %{state | node: new_node}}
  end
  
  # Forensic Analysis Helpers
  
  defp interpret_exit_code(0), do: "Clean Exit"
  defp interpret_exit_code(1), do: "General Error"
  defp interpret_exit_code(137), do: "OOM Kill (SIGKILL)"
  defp interpret_exit_code(143), do: "Graceful Shutdown (SIGTERM)"
  defp interpret_exit_code(139), do: "Segmentation Fault"
  defp interpret_exit_code(134), do: "Abort Signal (SIGABRT)"
  defp interpret_exit_code(-1), do: "Unknown (Process Already Gone)"
  defp interpret_exit_code(code), do: "Exit Code #{code}"
  
  defp generate_forensic_tags(exit_code, classification) do
    base_tags = ["deceased", "ghost", classification]
    
    specific_tags = case exit_code do
      137 -> ["oom", "killed", "memory_exhaustion"]
      143 -> ["sigterm", "shutdown"]
      139 -> ["segfault", "crashed"]
      134 -> ["abort", "crashed"]
      0 -> ["clean_exit"]
      _ -> []
    end
    
    base_tags ++ specific_tags
  end


  # --- Infos ---

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
    # Usually meaningless for volatile nodes but good for parity
    {:noreply, state}
  end

  @impl true
  def handle_info(:metabolic_decay, %{ghost_metadata: %{is_ghost: true}} = state) do
    # Ghosts don't decay or recover energy. They are metabolically inert.
    {:noreply, state}
  end

  @impl true
  def handle_info(:metabolic_decay, state) do
    # CREMS nodes also maintain high activity/energy
    Process.send_after(self(), :metabolic_decay, 600_000)
    {:noreply, %{state | metabolic_energy: 1.0}}
  end

  @impl true
  def handle_info({:hebbian_reinforce, target_id, amount}, state) do
     # SHARED LOGIC: Route to buffer
     CMS.RegionalHebbianBuffer.buffer_update(state.node.id, [{target_id, amount}], state.region_id)
     {:noreply, state}
  end

  @impl true
  def handle_info({:query, query_context}, state) do
    # 1. Relevance Score ($R$)
    node_text = state.node.body.natural_language_fact
    query_text = Map.get(query_context, :query_text, "")
    
    # SHARED LOGIC: CognitiveMath
    relevance = CognitiveMath.calculate_relevance_score(
      state.node.head.embedding, 
      query_context.query_vector, 
      node_text, 
      query_text
    )

    # 2. Adjusted Threshold ($T_{adj}$) - Use Urgency Override if stressed?
    # Spec says: "EffectiveThreshold = BaseThreshold * (1.0 - CurrentStress)"
    # We map "CurrentStress" to GlobalInhibition for now, or internal stress if available.
    inhibition = CMS.ActivationEngine.get_global_inhibition_factor()
    
    # SHARED LOGIC: CognitiveMath
    # Note: internal_state logic might differ slightly if mapped differently, but Math is same.
    t_adj = CognitiveMath.calculate_adjusted_threshold(state.node.head.urgency_threshold, inhibition, state.node.head.cognitive_state)

    if relevance >= t_adj do
       Logger.info("[CREMS] Node #{state.node.id} responding to query. R=#{relevance}")
       CMS.QueryCoordinator.node_fired(
         query_context.query_id,
         state.node.id,
         relevance,
         state.node
       )
       {:noreply, %{state | last_query_context: query_context}}
    else
       {:noreply, %{state | last_query_context: query_context}}
    end
  end

  @impl true
  def handle_info({:activation, _source_id, _strength, _type, _trace, _ttl}, %{ghost_metadata: %{is_ghost: true}} = state) do
     # Ghost nodes are inert and do not propagate activation. 
     # They remain queryable but are no longer part of the active spreading activation network.
     {:noreply, state}
  end

  @impl true
  def handle_info({:activation, source_id, strength, type, trace, ttl}, state) do
    # Replicate Spreading Activation logic using Shared Math
    
    # 1. Loop Prevention
    if MapSet.member?(trace, state.node.id) do
       {:noreply, state}
    else
       # SHARED LOGIC: CognitiveMath (Associative Boost)
       boost = CognitiveMath.calculate_associative_boost(strength, 1.0, type, :default)
       
       # Local Relevance from context
       local_relevance = if state.last_query_context do
          node_text = state.node.body.natural_language_fact
          query_text = Map.get(state.last_query_context, :query_text, "")
          CognitiveMath.calculate_relevance_score(state.node.head.embedding, state.last_query_context.query_vector, node_text, query_text)
       else
          0.0
       end
       
       total_score = local_relevance + boost
       inhibition = CMS.ActivationEngine.get_global_inhibition_factor()
       t_adj = CognitiveMath.calculate_adjusted_threshold(state.node.head.urgency_threshold, inhibition, state.node.head.cognitive_state)

       if total_score >= t_adj do
          # Fire!
          new_trace = MapSet.put(trace, state.node.id)
          CMS.LogAppender.append_node_event(state.node.id, :node_fired, %{strength: total_score})
          
          # Hebbian Feedback (Shared Physics)
          region_id = state.region_id
          delta = boost * 0.1
          CMS.RegionalHebbianBuffer.buffer_update(source_id, [{state.node.id, delta}], region_id)
          
          # Propagate
          GenServer.cast(self(), {:fire_with_config, new_trace, ttl - 1})
          
          {:noreply, state}
       else
          {:noreply, state}
       end
    end
  end

  # --- Internal ---

  defp persist_node(new_node) do
    # For CREMS, we persist to Mnesia nodes_table as well for observability.
    # But often we can use a separate volatile_nodes table if disk I/O is a concern.
    # Given the spec requirement for unified cognitive model, we use nodes_table.
    try do
      if :mnesia.system_info(:is_running) == :yes and :nodes_table in :mnesia.system_info(:tables) do
        # CREMS specific mapping for nodes_table
        path_hash = UUID.uuid5(:oid, "crems:#{new_node.id}")
        parent_uuid = 
          case Enum.find(new_node.tail.hierarchical_edges, fn e -> e.type == :child_of end) do
            %{target_node_id: id} -> id
            _ -> nil
          end
        
        :mnesia.dirty_write({:nodes_table, 
          new_node.id, 
          path_hash, 
          parent_uuid, 
          new_node.head, 
          new_node.body, 
          new_node.tail, 
          new_node.body.data_tail.chrono_stack,
          %{}, # Provenance (Empty for volatile)
          new_node.antenna
        })
      end
    rescue
      _ -> :ok
    end
  end

  defp via_tuple(id), do: {:via, Registry, {CMS.NodeRegistry, id}}
end
