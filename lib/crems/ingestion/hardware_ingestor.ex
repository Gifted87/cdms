defmodule CREMS.Ingestion.HardwareIngestor do
  require Logger
  alias CMS.Tool.Embedder
  alias CREMS.{Node, NodeHead, NodeBody, NodeAntenna, NodeTail}
  alias CREMS.Agents.{NodeActor, HardwareSentinel, TrackingAgent}

  @moduledoc """
  Scans host hardware and instantiates 'Organ Nodes' in the cognitive graph.
  """

  def run(mother_node_id) do
    Logger.info("[HARDWARE] Modeling System Organs (CPU, RAM, Storage)...")

    # 1. CPU
    spawn_hardware_node(:cpu, "hw:cpu", "The System Central Processing Unit.", mother_node_id)

    # 2. RAM
    spawn_hardware_node(:ram, "hw:ram", "The System Random Access Memory.", mother_node_id)

    # 3. Storage (Root)
    spawn_hardware_node(:storage, "hw:storage:/", "The Primary System Storage (Root File System).", mother_node_id)
  end

  defp spawn_hardware_node(type, node_id, description, mother_id) do
    case Registry.lookup(CMS.NodeRegistry, node_id) do
      [{_pid, _}] -> 
        Logger.debug("[HARDWARE] Node #{node_id} already exists.")
        :ok
      [] ->
        # Generate Identity
        fact = description
        tags = ["hardware", Atom.to_string(type), "organ"]
        
        embedding = 
          case Embedder.generate(fact, "all-MiniLM-L6-v2") do
            {:ok, tensor} -> tensor
            {:error, _} -> Nx.broadcast(0.0, {384})
          end

        node = %Node{
          id: node_id,
          head: %NodeHead{
            embedding: embedding,
            urgency_threshold: 0.3, # Hardware nodes are prioritized
            cognitive_state: :steady
          },
          body: %NodeBody{
            natural_language_fact: fact,
            semantic_tags: tags,
            fid_state: :active,
            symbolic_link: {:hardware, type},
            fid_satisfaction: 1.0,
            fid_stress: 0.0,
            fid_strain: 0.0,
            fid_agility: 1.0,
            fid_physics_model: %{elasticity_coefficient: 1.0, saturation_point: 1.0},
            data_tail: %CREMS.DataTail{
              ownership: %{user: "root", group: "root"},
              chrono_stack: CREMS.ChronoStack.new(%{
                state: :active,
                satisfaction: 1.0,
                stress: 0.0,
                strain: 0.0,
                agility: 1.0
              })
            }
          },
          antenna: %NodeAntenna{gain: 1.0, spatial_coord: {0.0, 0.0, 0.0}},
          tail: %NodeTail{
            hierarchical_edges: [%{target: mother_id, type: :child_of}],
            communication_edges: [],
            dependency_edges: [],
            semantic_edges: [],
            symbiotic_edges: []
          }
        }

        # Start NodeActor
        {:ok, _act_pid} = NodeActor.start_link(node)
        
        # Start Hardware Sentinel
        HardwareSentinel.start_link(
          type: type,
          node_id: node_id,
          sampling_rate: 2000
        )

        # Start Tracking Agent
        TrackingAgent.start_link(
          node_id: node_id,
          target_id: {:hardware, type},
          history_limit: 50
        )

        Logger.info("[HARDWARE] Node [#{node_id}] instantiated and enervated.")
    end
  end
end
