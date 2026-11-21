defmodule CMS.Services.GenesisCrawler do
  @moduledoc """
  Orchestrates the formal Genesis process (Cold Boot).
  Handles Phase 1 (Awakening/Crawl) and Phase 2 (Binding/Mixer).
  """
  require Logger

  @doc """
  Runs a full Genesis on the target path.
  """
  def run(path, options \\ []) do
    path = Path.expand(path)
    Application.put_env(:acn_cms, :project_root, path)
    cognitive_mode = Keyword.get(options, :cognitive_mode, :generative)
    Logger.info("GENESIS: Initiating Cold Boot for #{path} (Mode: #{cognitive_mode})")

    with :ok <- check_connectivity(cognitive_mode),
         {:ok, drift_detected} <- __MODULE__.Phase1.run(path, options),
         :ok <- maybe_run_phase2(drift_detected, options) do
      Logger.info("GENESIS: Cold Boot COMPLETE. Full cognitive graph established.")
      {:ok, path}
    else
      {:error, reason} ->
        Logger.error("GENESIS: Cold Boot ABORTED - #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_run_phase2(drift_detected, options) do
    force = Keyword.get(options, :force_binding, false)
    
    cond do
      force -> 
        Logger.info("GENESIS: Phase 2 FORCE enabled.")
        __MODULE__.Phase2.run()
      drift_detected -> 
        Logger.info("GENESIS: Drift detected during Phase 1. Initiating Phase 2 Binding.")
        __MODULE__.Phase2.run()
      true ->
        Logger.info("GENESIS: No drift detected and binding is silent. Skipping Phase 2.")
        :ok
    end
  end

  defp check_connectivity(:deterministic) do
    Logger.info("GENESIS: Deterministic Mode enabled. Bypassing Gemini connectivity check.")
    :ok
  end

  defp check_connectivity(_) do
    Logger.info("GENESIS: Checking Gemini Connectivity...")
    case CMS.Infrastructure.GeminiBridge.summarize("system check", "gemini-2.5-flash-lite", nil) do
      {:ok, _} -> 
        Logger.info("GENESIS: Gemini Bridge ONLINE.")
        :ok
      {:error, reason} ->
        {:error, {:gemini_unreachable, reason}}
    end
  end

  defmodule Phase1 do
    @moduledoc "Phase 1: Awakening (Hierarchy Expansion)"
    require Logger

    def run(path, options) do
      Logger.info("GENESIS: Phase 1 (Awakening) starting...")
      
      # Start the Directory Agent to crawl
      # We use self() to listen for the wavefront_complete signal
      {:ok, pid} = CMS.NodeSupervisor.start_directory_agent(
        path, 
        nil, 
        {0.0, 0.0, 0}, 
        "m0", 
        Keyword.merge(options, [notify_pid: self()])
      )

      Logger.info("GENESIS: Wavefront expansion active...")

      # Wait for completion (sync barrier)
      receive do
        {:wavefront_complete, ^pid, drift_detected} -> 
          Logger.info("GENESIS: Phase 1 COMPLETE. (Drift: #{drift_detected})")
          {:ok, drift_detected}
      after
        # 15 minute timeout for large crawls
        900_000 -> 
          {:error, :wavefront_timeout}
      end
    end
  end

  defmodule Phase2 do
    @moduledoc "Phase 2: Binding (Synaptic Integration)"
    require Logger

    def run do
      Logger.info("GENESIS: Phase 2 (Binding) starting...")

      try do
        # Pass A: Semantic Binding
        # Seeds DriftIndex from full Mnesia state (all nodes, not just live actors),
        # then runs a global Scatter-Gather to forge bidirectional :semantic and
        # :contradicts edges. This is the backbone of Spreading Activation.
        Logger.info("GENESIS: Phase 2A — Semantic Binding (Scatter-Gather)...")
        {:ok, sem_stats} = CMS.Ingestion.SemanticBinder.run_pass()
        Logger.info("GENESIS: Phase 2A COMPLETE. #{inspect(sem_stats)}")

        # Pass B: Topological Binding
        # Resolves cross-file call-graph ghost nodes into concrete :calls/:imports edges.
        Logger.info("GENESIS: Phase 2B — Topological Binding (Call Graph)...")
        CMS.Ingestion.CallGraphBinder.run_pass()
        Logger.info("GENESIS: Phase 2B COMPLETE.")

        Logger.info("GENESIS: Phase 2 COMPLETE.")
        :ok
      rescue
        e ->
          Logger.error("GENESIS: Phase 2 CRASHED - #{inspect(e)}")
          {:error, {:binding_failure, e}}
      end
    end
  end
end
