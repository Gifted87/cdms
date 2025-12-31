defmodule CREMS.Ingestion.RuntimeSwarm do
  use GenServer
  require Logger

  alias CREMS.Node
  alias CREMS.NodeHead
  alias CREMS.NodeBody
  alias CREMS.NodeAntenna
  alias CREMS.NodeTail

  @moduledoc """
  The Genesis Orchestrator for CREMS.
  Behavior:
  - Instantiates the Mother Node.
  - Spawns the root ModellingAgent.
  """

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers the Genesis sequence to start modelling the OS/BEAM.
  """
  def start_genesis do
    GenServer.cast(__MODULE__, :genesis)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    # Manual Start Only: We do NOT trigger genesis automatically.
    # Waiting for user to call start_genesis/0.
    Logger.info("[SWARM] RuntimeSwarm started. Waiting for manual genesis...")
    {:ok, %{status: :initializing, mother_node_id: nil}}
  end

  @impl true
  def handle_cast(:genesis, state) do
     if state.status == :initializing do
        send(self(), :genesis_internal)
        {:noreply, state}
     else
        Logger.warning("[SWARM] Genesis already triggered!")
        {:noreply, state}
     end
  end

  @impl true
  def handle_info(:genesis_internal, state) do
    Logger.info("[SWARM] Initiating Runtime Genesis...")

    # 1. Mother Node Discovery
    mother_node = instantiate_mother_node()
    
    # 2. Injection: Spawn first ModellingAgent
    # Targeting PID 1 (OS Root) as the primary entry point
    spawn_root_agent(mother_node.id)

    {:noreply, %{state | status: :active, mother_node_id: mother_node.id}}
  end

  # --- Internal ---

  defp instantiate_mother_node() do
    node_id = "mother-0000-0000-0000-000000000001"
    
    node = %Node{
      id: node_id,
      head: %NodeHead{
        embedding: List.duplicate(0.0, 384), # Placeholder or static root embedding
        urgency_threshold: 0.1, # Extremely low threshold for the root
        cognitive_state: :steady
      },
      body: %NodeBody{
        natural_language_fact: "Mother_Node: The Host Kernel / Root Process Environment.",
        fid_state: :active,
        fid_telemetry: %{},
        fid_satisfaction: 1.0,
        fid_stress: 0.0,
        fid_strain: 0.0,
        fid_agility: 1.0,
        fid_effect: "Omnipresent and stable root environment.",
        symbolic_link: {:os_pid, 1}
      },
      antenna: %NodeAntenna{gain: 1.0, spatial_coord: {0.0, 0.0, 0.0}},
      tail: %NodeTail{
        hierarchical_edges: [],
        communication_edges: [],
        dependency_edges: [],
        semantic_edges: [],
        symbiotic_edges: []
      }
    }

    # Register/Start NodeActor
    case CREMS.Agents.NodeActor.start_link(node) do
      {:ok, _pid} -> 
        Logger.info("[SWARM] Mother Node [#{node_id}] instantiated at (0,0,0)")
        node
      {:error, {:already_started, _pid}} ->
        node
    end
  end

  defp spawn_root_agent(mother_id) do
    # Root PID is 1 for OS level traversal
    # In BEAM-only mode, we'd start at :erlang.whereis(:init) or similar.
    # Spec says: "Spawns the first ModellingAgent targeting the Root PID (PID 1 for OS)"
    CREMS.Ingestion.ModellingAgent.spawn_agent(1, %{parent_id: mother_id})
    
    # RIGOROUS FIX: Explicitly target the BEAM VM process to ensure Erlang-level modeling occurs
    # even if the OS traversal (from PID 1) fails to traverse to the BEAM process.
    beam_pid = System.pid() |> String.to_integer()
    if beam_pid != 1 do
       CREMS.Ingestion.ModellingAgent.spawn_agent(beam_pid, %{parent_id: mother_id})
    end
  end
end
