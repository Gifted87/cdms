defmodule CMS.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # -1. Guard Entry (The Git-Lock)
    # Critical: Ensures we own the data directory before touching any files.
    :ok = CMS.Infrastructure.InstanceGuard.guard_entry()

    # 0. Bootloader Logic (Synchronous)
    # Checks lock file. If mismatch, PURGES Mnesia/Vectors and Rehydrates from JSONL.
    # Mnesia MUST NOT be running yet, or it would have crashed on schema load.
    :ok = CMS.Persistence.Bootloader.run()
    
    # 0.5 Initialize Lock-Free Indices
    CMS.Core.Logic.DriftIndex.init()
    
    # 1. Start Mnesia (Safe now, either matches current arch or is fresh)
    :mnesia.start()
    
    # 1.5 Wait for tables to be fully loaded before proceeding
    # This prevents race conditions where code tries to access tables during load
    tables = [:epoch_log_index, :nodes_table, :crems_nodes_table, :vector_index]
    case :mnesia.wait_for_tables(tables, 30_000) do
      :ok -> :ok
      {:timeout, bad_tabs} -> 
        Logger.warning("Mnesia tables timeout during load: #{inspect(bad_tabs)}")
        :ok
      {:error, reason} ->
        Logger.error("Mnesia wait_for_tables failed: #{inspect(reason)}")
        :ok
    end
  
    children = [
      # 0. Infrastructure Guard (Process Monitor for Lock Cleanup)
      CMS.Infrastructure.InstanceGuard,

      # 0.1 HTTP Connection Pool
      {Finch, name: CMS.Finch, pools: %{:default => [size: 200]}},

      # 1. Core Registries
      {Registry, keys: :unique, name: CMS.NodeRegistry},
      {Registry, keys: :unique, name: CMS.QueryCoordinatorRegistry},

      # 2. Communication Backbone (Cognitive Bus)
      {Phoenix.PubSub, name: CMS.PubSub},

      # 3. Persistence Layer
      CMS.EpochManager,
      CMS.LogAppender,
      CMS.VectorRouter,
      CMS.SymbolicIndex,  # NEW: Path → PID lookup

      # 4. Learning & Regulation Layer
      CMS.ActivationEngine,
      CMS.HebbianBufferSupervisor,
      CMS.Core.Logic.PhysiologyEngine, # Phase 5: Metabolic Pulse Engine

      # 5. Ingestion & Query Services
      CMS.Ingestion.NodeRegistry,
      CMS.Infrastructure.GeminiBridge,
      CMS.Services.LiveWire,
      {Task.Supervisor, name: CMS.Ingestion.TaskSupervisor},
      CMS.BroadcastCoordinator,

      # 6. The Node Population
      CMS.NodeSupervisor,

      # 7. CREMS Genesis Swarm (Phase 5)
      {Task.Supervisor, name: CREMS.Ingestion.SwarmSupervisor},
      CREMS.Ingestion.RuntimeSwarm,
      
      # 8. CREMS Forensics & Ghost Management (Section 8: Necrosis Protocol)
      CREMS.Persistence.EpochLog,  # Cold storage for ghost node archives
      CREMS.Agents.GhostScavenger, # Automated scavenging of expired ghosts
      
      # Symbiosis (Phase 6)
      CREMS.Symbiosis.DefinitionLinker,
      {CMS.Web, port: Application.get_env(:acn_cms, :web_port, 4000)}
    ]

    opts = [strategy: :one_for_one, name: CMS.Supervisor]
    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # 7. Post-Boot Hydration
        # Spawns node processes from epoch logs.
        CMS.Recovery.Hydrator.run()

        # 8. Start Global Workflow if configured
        if target_dir = System.get_env("CDMS_TARGET_DIR") do
          Task.start(fn ->
            Process.sleep(1000)
            
            node_count = :mnesia.table_info(:nodes_table, :size)
            mode_str = System.get_env("CDMS_MODE") || "generative"
            mode = if mode_str == "deterministic", do: :deterministic, else: :mode_a_deep

            if node_count == 0 do
              Logger.info("Starting Cold Boot Genesis on: #{target_dir}")
            else
              Logger.info("Starting Drift Synchronization on: #{target_dir} (Existing Nodes: #{node_count})")
            end

            CMS.Services.GenesisCrawler.run(target_dir, cognitive_mode: mode)
          end)
        end

        {:ok, pid}

      error -> 
        error
    end
  end
end
