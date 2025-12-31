defmodule CREMS.Physics.PhantomEngine do
  require Logger

  @moduledoc """
  The Phantom Engine (The Simulator): Enables predictive "What-If" simulations without affecting live nodes.
  Reference: Spec 4.2 Module: CREMS.Physics.PhantomEngine.
  """

  # --- Data Structures ---

  defmodule SimulationRequest do
    defstruct [:node_id, :force_vector]
  end

  defmodule ForceVector do
    defstruct [:type, :magnitude]
  end

  defmodule PhantomNode do
    defstruct [:id, :body, :tail, :outcome, :satisfaction]
  end

  # --- Client API ---

  @doc """
  Runs a simulation based on a SimulationRequest.
  """
  def simulate(%SimulationRequest{} = request) do
    simulate_scenario(request.node_id, request.force_vector)
  end

  # --- Simulation Logic ---

  @doc """
  Algorithm: simulate_scenario(node_uuid, force_vector)
  """
  def simulate_scenario(node_id, %ForceVector{} = force_vector) do
    # 1. Clone (The Phantom): Synchronously fetch snapshot
    case fetch_snapshot(node_id) do
      {:error, _} -> 
        %{node_id: node_id, outcome: :error, reason: :node_not_found, children: []}
        
      snapshot ->
        # 2. Create in-memory PhantomNode
        phantom = %PhantomNode{
          id: snapshot.id,
          body: snapshot.body,
          tail: snapshot.tail,
          outcome: :ok,
          satisfaction: snapshot.body.fid_satisfaction
        }

        # 3. Extract fid:physics_model and fid:telemetry
        physics = phantom.body.fid_physics_model || %{elasticity_coefficient: 1.0, saturation_point: 1.0}
        
        # 4. Apply Physics (Elasticity Logic)
        input_force = force_vector.magnitude
        # Spec: Elasticity = Phantom.body.fid:physics_model.elasticity_coefficient
        elasticity = Map.get(physics, :elasticity_coefficient, 1.0)
        
        # FIX: Pull from top-level body field (CREMS.NodeBody.fid_stress)
        current_stress = phantom.body.fid_stress || 0.0

        # Formula: Predicted_Stress = Current_Stress * (Input_Force ^ Elasticity)
        predicted_stress = current_stress * :math.pow(input_force, elasticity)

        # 5. Check Saturation (Crash Prediction)
        # FIX: Pull from :cpu_usage inside telemetry (what Sentinels actually send)
        telemetry = phantom.body.fid_telemetry || %{}
        current_load = Map.get(telemetry, :cpu_usage, 0.0)
        
        predicted_load = current_load * input_force
        saturation_point = Map.get(physics, :saturation_point, 1.0)

        # Check for crash
        {phantom, outcome} = 
          if predicted_load > saturation_point do
             # Set Phantom.outcome = :crashed. Set Phantom.satisfaction = 0.0.
             {%{phantom | outcome: :crashed, satisfaction: 0.0}, :crashed}
          else
             {phantom, :ok}
          end

        # 6. Propagate (The Dark Matter Push)
        children = 
          if outcome != :crashed do
             # Iterate Phantom.tail.communication_edges
             propagate(phantom.tail.communication_edges, input_force)
          else
             []
          end

        # Aggregate Result
        %{
          node_id: node_id,
          outcome: outcome,
          predicted_stats: %{
            stress: predicted_stress,
            load: predicted_load,
            satisfaction: phantom.satisfaction
          },
          children: children
        }
    end
  end

  # --- Helpers ---

  defp fetch_snapshot(node_id) do
    case Registry.lookup(CMS.NodeRegistry, node_id) do
      [{pid, _}] -> 
         try do
           GenServer.call(pid, :get_phantom_snapshot, 5000)
         catch
           :exit, _ -> {:error, :timeout}
         end
      [] -> {:error, :not_found}
    end
  end

  defp propagate(nil, _), do: []
  defp propagate(edges, input_force) when is_list(edges) do
     Enum.map(edges, fn 
        {:communicates_with, target_id, _proto, transfer_ratio} ->
             # Downstream_Force_Mag = Input_Force * transfer_ratio
             downstream_mag = input_force * transfer_ratio
             
             # Recursively call simulate_scenario
             simulate_scenario(target_id, %ForceVector{type: :propagation, magnitude: downstream_mag})
        _ -> nil
     end)
     |> Enum.reject(&is_nil/1)
  end
  defp propagate(_, _), do: []
end
