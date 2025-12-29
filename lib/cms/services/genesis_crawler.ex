defmodule CMS.Services.GenesisCrawler do
  @moduledoc """
  Orchestrates the formal Genesis process (Cold Boot).
  Handles Phase 1 (Awakening/Crawl) and Phase 2 (Binding/Mixer).
  """
  require Logger

  @summary_model "qwen3:0.6b"

  @doc """
  Runs a full Genesis on the target path.
  """
  def run(path, options \\ []) do
    path = Path.expand(path)
    Logger.info("GENESIS: Initiating Cold Boot for #{path}")

    with :ok <- check_connectivity(),
         :ok <- __MODULE__.Phase1.run(path, options),
         :ok <- __MODULE__.Phase2.run() do
      Logger.info("GENESIS: Cold Boot COMPLETE. Full cognitive graph established.")
      {:ok, path}
    else
      {:error, reason} ->
        Logger.error("GENESIS: Cold Boot ABORTED - #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp check_connectivity do
    Logger.info("GENESIS: Checking Ollama Connectivity...")
    case CMS.Infrastructure.OllamaBridge.summarize("system check", @summary_model, nil) do
      {:ok, _} -> 
        Logger.info("GENESIS: Ollama Bridge ONLINE.")
        :ok
      {:error, reason} ->
        {:error, {:ollama_unreachable, reason}}
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
        {:wavefront_complete, ^pid} -> 
          Logger.info("GENESIS: Phase 1 COMPLETE.")
          :ok
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
      
      # Establish semantic and connectome links
      try do
        CMS.Services.SystemMixer.bind_all()
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
