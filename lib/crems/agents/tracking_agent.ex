defmodule CREMS.Agents.TrackingAgent do
  use GenServer
  require Logger

  @moduledoc """
  The Vigilant Observer (Phase 7).
  While the Sentinel feels (fast loop), the Tracker remembers and learns (slow loop).
  
  Roles:
  1. Significant State Archival (Memory).
  2. Curve Fitting (Learning Physics for Phantom Manifold).
  """

  defstruct [
    :node_id, 
    :target_id, 
    :history_limit,
    :last_snapshot_hash,
    :last_state
  ]

  # --- Client API ---

  def start_link(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(node_id))
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    target_id = Keyword.fetch!(opts, :target_id)
    history_limit = Keyword.get(opts, :history_limit, 50)

    # Vigilant Loop: 1 second wakeup
    Process.send_after(self(), :observe, 1000)
    
    Logger.info("[TRACKER] Vigilant Observer started for Node #{node_id}")
    
    {:ok, %__MODULE__{
      node_id: node_id, 
      target_id: target_id, 
      history_limit: history_limit,
      last_snapshot_hash: nil,
      last_state: nil
    }}
  end

  @impl true
  def handle_cast(:trigger_archival, state) do
    # Immediate wake-up on Sentinel Event (Role 1)
    new_state = observe_reality(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:record_event, type, metadata}, state) do
    Logger.debug("[TRACKER] Event recorded for #{state.node_id}: #{type} | #{inspect(metadata)}")
    # We can expand this later to persist significant events to the ChronoStack
    {:noreply, state}
  end

  @impl true
  def handle_cast({:execute_autopsy, exit_code, final_buffer}, state) do
    Logger.warning("[TRACKER] AUTOPSY PROTOCOL: Executing for Node #{state.node_id}. Exit Code: #{exit_code}")
    
    # Section 8.2: The Autopsy Protocol
    
    # 1. Retrieve current node state (Last Known State)
    case get_node_snapshot(state.node_id) do
      {:ok, node} ->
        # 2. Determine death classification
        is_crashed = exit_code != 0
        death_state = if is_crashed, do: :crashed, else: :terminated
        
        Logger.info("[TRACKER] Death Classification: #{death_state} (Exit Code: #{exit_code})")
        
        # 3. Update Node State via NodeActor
        state_updates = %{
          fid_state: :terminated,  # Unified state
          fid_satisfaction: if(is_crashed, do: 0.0, else: node.body.fid_satisfaction),
          fid_output: final_buffer
        }
        
        # Apply state updates
        case Registry.lookup(CMS.NodeRegistry, state.node_id) do
          [{pid, _}] ->
            # Update physiological state
            GenServer.cast(pid, {:update_death_state, state_updates})
            
            # 4. Final Archive: Push active state to ChronoStack
            # This preserves the crash context (High Stress/Strain)
            final_snapshot = %{
              id: node.id,
              head_config: %{
                urgency: node.head.urgency_threshold,
                state: node.head.cognitive_state
              },
              physiology: %{
                state: :terminated,
                satisfaction: state_updates.fid_satisfaction,
                stress: node.body.fid_stress,
                strain: node.body.fid_strain,
                agility: node.body.fid_agility,
                telemetry: node.body.fid_telemetry,
                effect: node.body.fid_effect,
                exit_code: exit_code,
                final_output: final_buffer
              },
              topology: %{
                hierarchical: node.tail.hierarchical_edges,
                communication_count: length(node.tail.communication_edges),
                dependency_count: length(node.tail.dependency_edges)
              },
              timestamp: DateTime.utc_now(),
              death_classification: death_state
            }
            
            GenServer.cast(pid, {:push_history, final_snapshot})
            
            # 5. Trigger Ghost Transition (Section 8.3)
            retention_hours = Application.get_env(:cms, :crems_ghost_retention_hours, 24)
            retention_expiry = DateTime.add(DateTime.utc_now(), retention_hours * 3600, :second)
            
            GenServer.cast(pid, {:enter_ghost_mode, exit_code, final_snapshot, retention_expiry})
            
            Logger.info("[TRACKER] Autopsy complete. Node #{state.node_id} transitioned to Ghost Mode. Expiry: #{retention_expiry}")
            
          [] ->
            Logger.error("[TRACKER] NodeActor not found during autopsy for #{state.node_id}")
        end
        
        # 6. Tracker Terminates (Resource Release)
        {:stop, :normal, state}
        
      {:error, reason} ->
        Logger.error("[TRACKER] Failed to retrieve node state during autopsy: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(:observe, state) do
    new_state = observe_reality(state)
    
    # Schedule next observation (Periodic Role 1)
    Process.send_after(self(), :observe, 1000)
    {:noreply, new_state}
  end

  # --- Internal Logic ---

  defp observe_reality(state) do
    case get_node_snapshot(state.node_id) do
      {:ok, node} ->
        # 1. Evaluate Significance
        current_hash = compute_hash(node)
        
        if significant_change?(node, state) or current_hash != state.last_snapshot_hash do
          archive_state(node)
          learn_physics(node)
          %{state | last_snapshot_hash: current_hash, last_state: node}
        else
          state
        end
        
      _ -> state
    end
  end

  defp get_node_snapshot(node_id) do
    case Registry.lookup(CMS.NodeRegistry, node_id) do
      [{pid, _}] -> GenServer.call(pid, :get_state_snapshot)
      _ -> {:error, :not_found}
    end
  end

  defp compute_hash(node) do
    # Only hash relevant parts for noise rejection
    # We care about identity, state, and topology
    data_to_hash = {
      :ignore_state, # Patched: State ignored in hash to prevent blinking loops
      node.body.natural_language_fact,
      length(node.tail.hierarchical_edges),
      length(node.tail.communication_edges)
    }
    :crypto.hash(:sha256, :erlang.term_to_binary(data_to_hash)) |> Base.encode16()
  end

  defp significant_change?(node, state) do
    old_node = state.last_state
    
    cond do
      is_nil(old_node) -> true
      
      # 1. State Change
      normalize_state(node.body.fid_state) != normalize_state(old_node.body.fid_state) -> true
      
      # 2. Topology Change (New Child / Parent / Network Link)
      length(node.tail.hierarchical_edges) != length(old_node.tail.hierarchical_edges) or
      length(node.tail.communication_edges) != length(old_node.tail.communication_edges) -> true
      
      # 3. Satisfaction Collapse
      node.body.fid_satisfaction < 0.5 and old_node.body.fid_satisfaction >= 0.5 -> true
      
      # 4. Stress Jump (Transition from Low/Normal to Critical)
      (old_node.body.fid_stress < 0.5 and node.body.fid_stress > 0.8) -> true
      
      true -> false
    end
  end

  defp archive_state(node) do
    Logger.info("[TRACKER] Significant transition detected for #{node.id}. Archiving to ChronoStack.")
    
    # Snapshot: A deep copy of the Node state (Spec 7.1)
    # We strip the large artifacts like embeddings or chrono_stack itself to avoid recursive bloat,
    # but keep all logical state, config, relationships, and "feelings".
    snapshot_data = %{
      id: node.id,
      head_config: %{
        urgency: node.head.urgency_threshold,
        state: node.head.cognitive_state
      },
      physiology: %{
        state: :ignore_state, # Patched: State ignored in hash to prevent blinking loops
        satisfaction: node.body.fid_satisfaction,
        stress: node.body.fid_stress,
        strain: node.body.fid_strain,
        agility: node.body.fid_agility,
        telemetry: node.body.fid_telemetry,
        effect: node.body.fid_effect
      },
      topology: %{
        hierarchical: node.tail.hierarchical_edges, # Spec: Relationships (Deep copy)
        communication_count: length(node.tail.communication_edges),
        dependency_count: length(node.tail.dependency_edges)
      },
      timestamp: DateTime.utc_now()
    }
    
    case Registry.lookup(CMS.NodeRegistry, node.id) do
      [{pid, _}] -> GenServer.cast(pid, {:push_history, snapshot_data})
      _ -> :ok
    end
  end

  # --- Role 2: Curve Fitting (Learning Physics) ---

  defp learn_physics(node) do
    # Scan: Reads the local ChronoStack history (Spec 7.2)
    history = node.body.data_tail.chrono_stack.stack_layers
    
    if length(history) > 4 do
       # Correlate: Plots Input_Load vs Stress vs Agility (Spec 7.2)
       data_points = Enum.map(history, fn snap ->
         # Input_Load (Network/Message Volume) as per Spec 7.2 Role 2
         
         # Handle polymorphic snapshot structure (Nested vs Flat Initial)
         data = snap.data
         
         {physiology, topology} = 
           case Map.get(data, :physiology) do
             nil -> 
               # Flat Initial State (Fallback)
               {data, %{communication_count: 0}}
             phys -> 
               # Nested Standard State
               {phys, Map.get(data, :topology) || %{}}
           end

         telemetry = Map.get(physiology, :telemetry) || %{}
         
         # Safe access to communication_count (struct or map)
         comm_count = Map.get(topology, :communication_count, 0)
         
         load = comm_count + (Map.get(telemetry, "cpu_usage", 0.0) * 10)
         
         %{load: load, stress: Map.get(physiology, :stress, 0.0), agility: Map.get(physiology, :agility, 0.0)}
       end)

       # 1. Derive elasticity_coefficient (Spec 7.2)
       # For exponential "Hockey Stick" detection, we use log-log regression:
       # log(Stress) = elasticity * log(Load)
       # We add small epsilon to avoid log(0)
       log_points = 
         data_points 
         |> Enum.map(fn p -> {:math.log(max(p.load, 0.001)), :math.log(max(p.stress, 0.001))} end)
       
       elasticity = 
         case CMS.Core.Logic.CognitiveMath.linear_regression(log_points) do
           {:ok, %{slope: m}} -> max(1.0, m)
           _ -> 1.0
         end

       # 2. Derive saturation_point (Spec 7.2)
       # Finds the load value where Agility historically collapsed to near zero via regression projection.
       agility_points = Enum.map(data_points, fn p -> {p.load, p.agility} end)
       
       saturation_point = 
         case CMS.Core.Logic.CognitiveMath.linear_regression(agility_points) do
           {:ok, %{slope: m, intercept: b}} when m < 0 ->
             # Agility = m * Load + b. Set Agility = 0 -> Load = -b/m
             # We want the x-intercept
             x_intercept = -b / m
             # If Agility is already low in history, use the min load where it was low as a safe floor
             historical_floor = 
               data_points 
               |> Enum.filter(&(&1.agility < 0.2)) 
               |> Enum.map(& &1.load) 
               |> case do
                 [] -> x_intercept
                 loads -> Enum.min(loads)
               end
             min(x_intercept, historical_floor) |> max(1.0)

           _ -> 
             # Fallback to simple heuristic if data is flat or rising
             data_points 
             |> Enum.filter(&(&1.agility < 0.2)) 
             |> Enum.map(& &1.load) 
             |> case do
               [] -> 1.0 
               loads -> Enum.min(loads) |> max(1.0)
             end
          end

       Logger.debug("[TRACKER] Physics Derived for #{node.id}: Elasticity=#{Float.round(elasticity, 2)}, Saturation=#{Float.round(saturation_point, 2)}")
       
       # Update: Writes learned constants to fid:physics_model (Spec 7.2)
       case Registry.lookup(CMS.NodeRegistry, node.id) do
         [{pid, _}] -> 
           GenServer.cast(pid, {
             :update_model_constants, 
             %{elasticity_coefficient: elasticity, saturation_point: saturation_point}
           })
         _ -> :ok
       end
    end
  end
  defp via_tuple(node_id) do
    {:via, Registry, {CMS.NodeRegistry, {:tracking_agent, node_id}}}
  end

  # --- Patch Helpers ---
  defp normalize_state(state) when state in [:running, :runnable, :waiting, :sleeping, :active], do: :alive
  defp normalize_state(state), do: state
end
