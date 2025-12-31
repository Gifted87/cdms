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
    if should_skip_os_process?(pid) do
       # Skip non-essential OS processes (lsof, pgrep, etc) early
       :ok
    else
      # 0. IDEMPOTENCY CHECK
      # We derive the ID first to check if we've already modelled this node.
      {node_id, _link} = derive_node_id(pid)

      if Registry.lookup(CMS.NodeRegistry, node_id) != [] do
         # Node exists. We skip expensive scanning/embedding.
         # CRITICAL FIX: We do NOT trigger reproduction for existing nodes here anymore.
         # This prevents the "Recursive Discovery Storm" where every check triggers a full walk.
         Logger.debug("[SWARM] Node #{node_id} already exists. Skipping.")
         :ok
      else
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
                  
                  # 7. TERMINATE
                  Logger.info("[SWARM] ModellingAgent completed for PID #{pid} (Node: #{node.id})")
                  
               {:error, :already_exists} -> 
                  # Race condition catch
                  Logger.debug("[SWARM] Node for PID #{pid} already exists (race). Skipping.")
             end
    
          {:error, reason} ->
             Logger.debug("[SWARM] Could not scan PID #{pid}: #{reason}")
        end
      end
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
    # Use shared helper
    {node_id, symbol_link} = derive_node_id(pid)
     
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
          PhysiologySentinel.start_link(
            target_pid: os_pid,
            node_id: node.id,
            sampling_rate: 1000
          )
        {:beam_pid, beam_pid} ->
          BeamSentinel.start_link(
            target_pid: beam_pid,
            node_id: node.id,
            sampling_rate: 1000
          )
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
    # Iterate through all internal processes, filtering out CREMS infrastructure
    all_processes = Process.list()
    filtered_processes = Enum.reject(all_processes, &should_skip_erlang_process?/1)
    
    Logger.info("[SWARM] Modeling Erlang processes: #{length(filtered_processes)} of #{length(all_processes)} (filtered #{length(all_processes) - length(filtered_processes)} infrastructure processes)")
    
    filtered_processes
    |> Task.async_stream(fn erl_pid ->
       # Small jitter to spread the load of concurrent scans
       Process.sleep(Enum.random(10..50))
       run_erlang_agent(erl_pid, parent_node_id)
    end, max_concurrency: 15, timeout: 30_000, on_timeout: :kill)
    |> Stream.run()
  end

  defp run_erlang_agent(pid, parent_id) do
       # 0. INFRASTRUCTURE CHECK
       if should_skip_erlang_process?(pid) do
          Logger.debug("[SWARM] Skipping CREMS infrastructure process: #{inspect(pid)}")
          :ok
       else
         # 1. IDEMPOTENCY CHECK
         {node_id, _link} = derive_node_id(pid)
         
         if Registry.lookup(CMS.NodeRegistry, node_id) != [] do
            Logger.debug("[SWARM] Erlang Node #{node_id} already exists. Skipping.")
            :ok
         else
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
       end
       end
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

  defp should_skip_os_process?(pid) when is_integer(pid) do
    # TRAVERSAL ANCHOR: Always allow PID 1
    if pid == 1, do: false, else: do_skip_os_check(pid)
  end

  defp do_skip_os_check(pid) do
    # Skip non-essential system processes and our own tools to reduce load
    case File.read("/proc/#{pid}/comm") do
      {:ok, comm} ->
        name = String.trim(comm)
        
        # Blacklist of noisy or irrelevant processes
        blacklist = [] # FILTER DISABLED BY USER
        
        is_blacklisted = Enum.any?(blacklist, fn b -> String.contains?(name, b) end)
        
        if is_blacklisted do
          Logger.debug("[SWARM] Skipping OS-level infrastructure process: #{name} (PID #{pid})")
          true
        else
          false
        end

      {:error, _} -> true # Assume vanished or inaccessible
    end
  end

  defp should_skip_os_process?(_), do: false

  
  # --- STRICT FILTER: GENSERVERS ONLY ---
  # --- DEEP INTROSPECTION FILTER ---
  defp should_skip_erlang_process?(pid) do
    # 1. First check the infrastructure blacklist (Safety)
    if check_infrastructure_blacklist(pid) do
      true
    else
      # 2. Then check if it is a Significant OTP Behaviour (GenServer, Supervisor, Agent)
      not is_significant_process?(pid)
    end
  end

  defp is_significant_process?(pid) do
    # :proc_lib.translate_initial_call is CRITICAL. 
    # Without it, we only see {:proc_lib, :init_p, 5} instead of {MyApp.Server, ...}
    case :proc_lib.translate_initial_call(pid) do
      {module, _, _} -> is_behavioural_module?(module)
      _ -> false
    end
  end

  defp is_behavioural_module?(module) do
    try do
      if Code.ensure_loaded?(module) do
        # Get behaviours. Elixir stores them in :behaviour (list), Erlang often same.
        attribs = module.module_info(:attributes)
        behaviours = Keyword.get(attribs, :behaviour, [])
        
        # Targets: GenServer, Supervisor, Agent (and their Erlang lowercase equivalents)
        targets = [GenServer, :gen_server, Supervisor, :supervisor, Agent, :agent]
        
        Enum.any?(targets, fn t -> t in behaviours end)
      else
        false
      end
    rescue
      _ -> false
    end
  end
  
  # --- Infrastructure Blacklist (Renamed/Preserved) ---
  defp check_infrastructure_blacklist(pid) do

    # Skip CREMS infrastructure to prevent infinite modeling cascade
    case Process.info(pid, [:registered_name, :initial_call, :dictionary]) do
      nil -> 
        true  # Process died, skip it
      
      info ->
        registered_name = Keyword.get(info, :registered_name)
        initial_call = Keyword.get(info, :initial_call)
        dictionary = Keyword.get(info, :dictionary, [])
        
        # Skip if registered under CREMS/CMS namespace
        skip_by_name = case registered_name do
          name when is_atom(name) ->
            name_str = Atom.to_string(name)
            String.starts_with?(name_str, "Elixir.CREMS") or
            String.starts_with?(name_str, "Elixir.CMS") or
            String.starts_with?(name_str, "CREMS.") or
            String.starts_with?(name_str, "CMS.")
          _ -> false
        end
        
        # Skip Task.Supervisor workers (includes ModellingAgents)
        skip_by_initial = case initial_call do
          {Task.Supervised, _, _} -> true
          {Task, _, _} -> true
          _ -> false
        end
        
        # Skip if spawned by our SwarmSupervisor (check ancestors)
        skip_by_ancestry = case Keyword.get(dictionary, :"$ancestors") do
          ancestors when is_list(ancestors) ->
            Enum.any?(ancestors, fn ancestor ->
              case ancestor do
                name when is_atom(name) ->
                  name_str = Atom.to_string(name)
                  String.contains?(name_str, "SwarmSupervisor") or
                  String.contains?(name_str, "CREMS.Ingestion")
                _ -> false
              end
            end)
          _ -> false
        end
        
        # Skip core infrastructure
        skip_by_module = case initial_call do
          {GenServer, _, _} -> 
            # Allow GenServers unless they're explicitly CREMS/CMS
            false
          {Supervisor, _, _} -> true
          {Registry, _, _} -> true
          {:proc_lib, :init_p, _} -> true
          _ -> false
        end
        
        skip_by_name or skip_by_initial or skip_by_ancestry or skip_by_module
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

  defp derive_node_id(pid) do
    case pid do
      p when is_integer(p) -> 
        {"pid-node-#{p}", {:os_pid, p}}
      p when is_pid(p) -> 
        # Extract a unique string from PID for registry
        # PID format: #PID<0.123.0>
        pid_str = inspect(p) |> String.replace(~r/[<>#PID.]/, "-") |> String.trim("-")
        {"beam-node-#{pid_str}", {:beam_pid, p}}
    end
  end
end
