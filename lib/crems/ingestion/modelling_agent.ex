defmodule CREMS.Ingestion.ModellingAgent do
  use Task, restart: :temporary
  require Logger

  alias CREMS.Ingestion.IdentityFactory
  alias CREMS.Ingestion.EdgeForger
  alias CMS.Core.Logic.EdgeGenerator
  alias CMS.Tool.Embedder
  alias CREMS.{Node, NodeHead, NodeBody, NodeAntenna, NodeTail}
  alias CREMS.Agents.{NodeActor, PhysiologySentinel, TrackingAgent, BeamSentinel}

  @moduledoc """
  An ephemeral worker for modelling one node.
  Implements the 7-step sequence: Scan, Identify, Spawn, Wire, Enervate, Reproduce, Terminate.
  """

  # --- Client API ---

  def spawn_agent(pid, context) do
     Task.Supervisor.start_child(CREMS.Ingestion.SwarmSupervisor, fn ->
       run(pid, context)
     end)
  end

  # --- Lifecycle Flow ---

  def run(pid, context) do
    Logger.debug("[SWARM] ModellingAgent starting for PID #{pid}")

    # 1. SCAN
    case scan_process(pid) do
      {:ok, raw_data} ->
         
         # 2. IDENTIFY
         identity = identify_node(pid, raw_data)
         
         # 3. SPAWN
         case spawn_actor(pid, identity, context) do
           {:ok, node} ->
              # 4. WIRE
              wire_node(pid, node, context)
              
              # 5. ENERVATE
              enervate_node(pid, node)
              
              # 6. REPRODUCE
              reproduce(pid, node.id)
              
              # 7. TERMINATE (Implicit on function exit)
              Logger.info("[SWARM] ModellingAgent completed for PID #{pid} (Node: #{node.id})")
              
           {:error, :already_exists} -> 
              Logger.debug("[SWARM] Node for PID #{pid} already exists. Skipping reproduction branch.")
         end

      {:error, reason} ->
         Logger.debug("[SWARM] Could not scan PID #{pid}: #{reason}")
    end
  end

  # --- Step 1: SCAN ---
  defp scan_process(pid) do
     if File.exists?("/proc/#{pid}/status") do
        status = File.read!("/proc/#{pid}/status")
        # Extract binary name, user, etc.
        bin = extract_field(status, "Name")
        uid_str = extract_field(status, "Uid") |> String.split("\t") |> List.first()
        gid_str = extract_field(status, "Gid") |> String.split("\t") |> List.first()
        uid = String.to_integer(uid_str)
        gid = String.to_integer(gid_str)
        user_name = EdgeForger.resolve_user(uid)
        
        args = case File.read("/proc/#{pid}/cmdline") do
          {:ok, content} -> String.replace(content, <<0>>, " ") |> String.trim()
          _ -> ""
        end
        
        # Extracts Ports (Spec requirement)
        ports = EdgeForger.extract_ports(pid)
        exe_path = EdgeForger.get_executable_path(pid)
        
        {:ok, %{
          binary_name: bin,
          user: user_name,
          uid: uid,
          gid: gid,
          args: args,
          ports: ports,
          exe_path: exe_path
        }}
     else
        {:error, :not_found}
     end
  end

  # --- Step 2: IDENTIFY ---
  defp identify_node(_pid, raw_data) do
     fact = IdentityFactory.generate_fact(raw_data)
     tags = IdentityFactory.generate_tags(raw_data)
     
     # CDMS Embedder call using CMS.Tool.Embedder.generate/2
     embedding = 
       case Embedder.generate(fact, "all-MiniLM-L6-v2") do
         {:ok, tensor} -> tensor
         {:error, reason} -> 
           Logger.error("[SWARM] Embedding failed for fact: #{fact}. Reason: #{inspect(reason)}")
           # Fallback: Zero vector
           Nx.broadcast(0.0, {384})
       end

     %{
       fact: fact,
       tags: tags,
       embedding: embedding,
       raw_data: raw_data
     }
  end

  # --- Step 3: SPAWN ---
  defp spawn_actor(pid, identity, _context) do
    # 1. Determine ID and Link type
    {node_id, symbol_link} = 
      case pid do
        p when is_integer(p) -> {"pid-node-#{p}", {:os_pid, p}}
        p when is_pid(p) -> 
          # Extract a unique string from PID for registry
          # PID format: #PID<0.123.0>
          pid_str = inspect(p) |> String.replace(~r/[<>#PID.]/, "-") |> String.trim("-")
          {"beam-node-#{pid_str}", {:beam_pid, p}}
      end
     
     case Registry.lookup(CMS.NodeRegistry, node_id) do
       [{_pid, _}] -> {:error, :already_exists}
       [] -> 
          node = %Node{
            id: node_id,
            head: %NodeHead{
              embedding: identity.embedding,
              urgency_threshold: 0.5,
              cognitive_state: :steady
            },
            body: %NodeBody{
              natural_language_fact: identity.fact,
              semantic_tags: identity.tags,
              fid_state: :active,
              symbolic_link: symbol_link,
              executable_path: Map.get(identity.raw_data, :exe_path),
              data_tail: %CREMS.DataTail{
                ownership: %{
                  uid: Map.get(identity.raw_data, :uid, 0),
                  user: Map.get(identity.raw_data, :user, "beam"),
                  gid: Map.get(identity.raw_data, :gid, 0),
                  group: "beam"
                },
                capabilities: [],
                chrono_stack: CREMS.ChronoStack.new(%{
                  state: :active,
                  satisfaction: 1.0,
                  stress: 0.0,
                  strain: 0.0,
                  agility: 1.0
                })
              },
              fid_satisfaction: 1.0,
              fid_stress: 0.0,
              fid_strain: 0.0,
              fid_agility: 1.0,
              fid_physics_model: %{elasticity_coefficient: 1.0, saturation_point: 1.0}
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
          
          NodeActor.start_link(node)
          {:ok, node}
     end
  end

  # --- Step 4: WIRE ---
  defp wire_node(pid, node, context) do
     # Hierarchy: Scans PPID (Parent PID) - Rigorous Implementation
     ppid = EdgeForger.get_parent_id(pid)
     parent_node_id = 
       cond do
         ppid && ppid > 0 -> "pid-node-#{ppid}"
         # Fallback to context if PPID scan yields root or invalid
         true -> context[:parent_id]
       end

     if parent_node_id do
        send_edge_update(node.id, :child_of, parent_node_id)
     end
     
     # Dependency & Communication (EdgeForger)
     comm_edges = EdgeForger.forge_communication_edges(pid)
     Enum.each(comm_edges, fn {target, proto, ratio} -> 
        send_edge_update(node.id, :communicates_with, target, %{proto: proto, ratio: ratio})
     end)
     
     dep_edges = EdgeForger.forge_dependency_edges(pid)
     Enum.each(dep_edges, fn target ->
        send_edge_update(node.id, :depends_on, target)
     end)

     # Semantic (Shared CDMS Logic)
     # Triggers EdgeGenerator.prime_candidates/2 (CDMS Logic) to find semantic neighbors.
     candidates = EdgeGenerator.prime_candidates(node.head.embedding, node.id)
     Enum.each(candidates, fn {target_id, score} -> 
        send_edge_update(node.id, :semantically_related_to, target_id, %{score: score})
     end)

      # Symbiosis: Link to CDMS Definition (Phase 6)
      CREMS.Symbiosis.DefinitionLinker.link_node(node.id)
  end

  # --- Step 5: ENERVATE ---
  defp enervate_node(pid, node) do
     # 1. Spawn Physiology Sentinel (Feeling Loop)
     case node.body.symbolic_link do
       {:os_pid, os_pid} ->
         PhysiologySentinel.start_link(%{
           target_pid: os_pid,
           node_id: node.id,
           sampling_rate: 1000
         })
       {:beam_pid, beam_pid} ->
         BeamSentinel.start_link(%{
           target_pid: beam_pid,
           node_id: node.id,
           sampling_rate: 1000
         })
     end
     
     # 2. Spawn Tracking Agent (Learning/History)
     target_id = node.body.symbolic_link
     {:ok, tracking_pid} = TrackingAgent.start_link(
       node_id: node.id,
       target_id: target_id,
       history_limit: 50
     )
     
     # Record Creation Event (Thorough Implementation)
     GenServer.cast(tracking_pid, {:record_event, :node_created, %{pid: pid, timestamp: DateTime.utc_now()}})
  end

  # --- Step 6: REPRODUCE ---
  def reproduce(pid, node_id) do
     # OS-level reproduction
     if is_integer(pid) do
       child_pids = EdgeForger.get_child_pids(pid)
       Enum.each(child_pids, fn child_pid ->
          spawn_agent(child_pid, %{parent_id: node_id})
       end)

       # SPECIAL: If this is the BEAM process, branch into Erlang processes
       if is_beam_process?(pid) do
         Logger.info("[SWARM] BEAM VM Detected (PID #{pid}). Branching into Erlang Process Swarm.")
         reproduce_erlang(node_id)
       end
     end
  end

  defp reproduce_erlang(parent_node_id) do
    # Iterate through all internal processes
    Process.list()
    |> Enum.each(fn erl_pid ->
       # Skip ourselves and common infrastructure if needed, 
       # but for full simulation we scan everything.
       spawn_erlang_agent(erl_pid, parent_node_id)
    end)
  end

  defp spawn_erlang_agent(pid, parent_id) do
    Task.Supervisor.start_child(CREMS.Ingestion.SwarmSupervisor, fn ->
       # 1. SCAN
       case scan_erlang_process(pid) do
         {:ok, raw_data} ->
            # 2. IDENTIFY
            identity = identify_node(pid, raw_data)
            
            # 3. SPAWN
            case spawn_actor(pid, identity, %{parent_id: parent_id}) do
              {:ok, node} ->
                 # 4. WIRE
                 # Hierarchy: link to the BEAM OS node
                 send_edge_update(node.id, :child_of, parent_id)
                 
                 # 5. ENERVATE
                 enervate_node(pid, node)
                 
                 Logger.debug("[SWARM] Erlang ModellingAgent completed for PID #{inspect(pid)}")
                 
              {:error, :already_exists} -> :ok
            end
         _ -> :ok
       end
    end)
  end

  defp scan_erlang_process(pid) do
    if Process.alive?(pid) do
      info = Process.info(pid, [:registered_name, :initial_call, :dictionary])
      {:ok, %{
        binary_name: "beam_process",
        registered_name: Keyword.get(info, :registered_name),
        initial_call: Keyword.get(info, :initial_call),
        is_erlang: true
      }}
    else
      {:error, :dead}
    end
  end

  defp is_beam_process?(pid) do
    # Check if the process name or cmdline contains 'beam'
    case File.read("/proc/#{pid}/cmdline") do
       {:ok, content} -> String.contains?(content, "beam.smp")
       _ -> false
    end
  end

  # --- Helpers ---

  defp extract_field(content, field) do
     content
     |> String.split("\n")
     |> Enum.find_value(fn line ->
        if String.starts_with?(line, field) do
           [_, val] = String.split(line, ":", parts: 2)
           String.trim(val)
        else
           nil
        end
     end)
  end

  defp send_edge_update(node_id, type, target, metadata \\ %{}) do
     case Registry.lookup(CMS.NodeRegistry, node_id) do
        [{pid, _}] -> 
           # We need a generic handle_cast for internal edge updates in NodeActor
           # Or just use the existing update mechanism
           GenServer.cast(pid, {:upsert_edge, type, target, metadata})
        _ -> :ok
     end
  end
end
