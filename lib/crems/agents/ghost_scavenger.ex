defmodule CREMS.Agents.GhostScavenger do
  @moduledoc """
  The Death Reaper: Automated Ghost Node Scavenger.
  
  Periodically scans for expired ghost nodes, archives their ChronoStacks
  to EpochLog for long-term forensic storage, and gracefully terminates them.
  
  Configuration:
  - Scan interval: Default 1 hour (configurable)
  - Retention period: Default 24 hours (configurable)
  """

  use GenServer
  require Logger

  alias CREMS.Persistence.EpochLog

  @default_interval_ms 3_600_000  # 1 hour
  @default_retention_hours 24

  defstruct [
    :scan_interval_ms,
    :retention_hours,
    :metrics
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a scavenge cycle (useful for testing).
  """
  def trigger_scavenge do
    GenServer.cast(__MODULE__, :scavenge)
  end

  @doc """
  Get scavenger metrics.
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    scan_interval = Keyword.get(opts, :scan_interval_ms, @default_interval_ms)
    retention_hours = Keyword.get(opts, :retention_hours, @default_retention_hours)

    # Schedule first scavenge
    schedule_scavenge(scan_interval)

    Logger.info("[GhostScavenger] Started. Scan interval: #{scan_interval}ms, Retention: #{retention_hours}h")

    {:ok, %__MODULE__{
      scan_interval_ms: scan_interval,
      retention_hours: retention_hours,
      metrics: %{
        total_scavenged: 0,
        total_archived: 0,
        last_scavenge_time: nil,
        errors: 0
      }
    }}
  end

  @impl true
  def handle_cast(:scavenge, state) do
    new_state = perform_scavenge(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, state.metrics, state}
  end

  @impl true
  def handle_info(:scavenge_tick, state) do
    new_state = perform_scavenge(state)
    schedule_scavenge(state.scan_interval_ms)
    {:noreply, new_state}
  end

  # --- Internal Logic ---

  defp perform_scavenge(state) do
    Logger.info("[GhostScavenger] Starting scavenge cycle...")
    start_time = System.monotonic_time(:millisecond)

    # 1. Find all registered CREMS nodes
    all_nodes = Registry.select(CMS.NodeRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])

    # 2. Filter for ghost nodes with expired retention
    expired_ghosts = 
      all_nodes
      |> Enum.filter(fn {node_id, pid} -> is_ghost_expired?(node_id, pid, state.retention_hours) end)

    ghost_count = length(expired_ghosts)
    Logger.info("[GhostScavenger] Found #{ghost_count} expired ghost(s)")

    # 3. Archive and terminate each expired ghost
    {archived, errors} = 
      Enum.reduce(expired_ghosts, {0, 0}, fn {node_id, pid}, {arch_acc, err_acc} ->
        case scavenge_ghost(node_id, pid) do
          :ok -> {arch_acc + 1, err_acc}
          :error -> {arch_acc, err_acc + 1}
        end
      end)

    elapsed = System.monotonic_time(:millisecond) - start_time
    
    Logger.info("[GhostScavenger] Cycle complete. Archived: #{archived}, Errors: #{errors}, Time: #{elapsed}ms")

    # Update metrics
    new_metrics = %{
      total_scavenged: state.metrics.total_scavenged + ghost_count,
      total_archived: state.metrics.total_archived + archived,
      last_scavenge_time: DateTime.utc_now(),
      errors: state.metrics.errors + errors
    }

    %{state | metrics: new_metrics}
  end

  defp is_ghost_expired?(_node_id, pid, _retention_hours) do
    try do
      # Request state snapshot
      case GenServer.call(pid, :get_state_snapshot, 5000) do
        {:ok, node} ->
          # Check if it has ghost metadata
          case node do
            %{ghost_metadata: %{is_ghost: true, retention_expiry: expiry}} ->
              DateTime.compare(DateTime.utc_now(), expiry) == :gt
            _ ->
              false
          end
        _ ->
          false
      end
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp scavenge_ghost(node_id, pid) do
    try do
      # 1. Get full state snapshot
      case GenServer.call(pid, :get_state_snapshot, 5000) do
        {:ok, node} ->
          # 2. Archive ChronoStack to EpochLog
          metadata = %{
            node_id: node_id,
            exit_code: get_in(node, [:ghost_metadata, :exit_code]) || -1,
            death_time: get_in(node, [:ghost_metadata, :death_time]) || DateTime.utc_now(),
            tags: node.body.semantic_tags || [],
            process_role: extract_process_role(node.body.natural_language_fact)
          }

          case EpochLog.archive_ghost(node_id, node.body.data_tail.chrono_stack, metadata) do
            {:ok, archive_path} ->
              Logger.info("[GhostScavenger] Archived ghost #{node_id} to #{archive_path}")

              # 3. Gracefully terminate the NodeActor
              Process.exit(pid, :scavenged)
              
              Logger.info("[GhostScavenger] Terminated ghost #{node_id}")
              :ok

            {:error, reason} ->
              Logger.error("[GhostScavenger] Failed to archive ghost #{node_id}: #{inspect(reason)}")
              :error
          end

        _ ->
          Logger.warning("[GhostScavenger] Failed to get state for ghost #{node_id}")
          :error
      end
    rescue
      e ->
        Logger.error("[GhostScavenger] Error scavenging ghost #{node_id}: #{inspect(e)}")
        :error
    catch
      :exit, reason ->
        Logger.error("[GhostScavenger] Exit while scavenging ghost #{node_id}: #{inspect(reason)}")
        :error
    end
  end

  defp extract_process_role(natural_language_fact) when is_binary(natural_language_fact) do
    # Try to extract role from facts like "I am a postgres process..."
    case Regex.run(~r/I am (?:a |an )?([a-z_]+)/i, natural_language_fact) do
      [_, role] -> role
      _ -> "unknown"
    end
  end
  defp extract_process_role(_), do: "unknown"

  defp schedule_scavenge(interval_ms) do
    Process.send_after(self(), :scavenge_tick, interval_ms)
  end
end
