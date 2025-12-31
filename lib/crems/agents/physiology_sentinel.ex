defmodule CREMS.Agents.PhysiologySentinel do
  use GenServer
  require Logger
  alias CREMS.Physics.Alchemist

  @moduledoc """
  The OS Alchemist: Monitors an OS process and transmutes its raw stats into Physiological Feelings.
  """

  defstruct [
    :node_id,
    :target_pid,      # Integer (OS PID)
    :sampling_rate,   # Milliseconds
    :last_metrics,    # Map: Stores previous values for delta calculation
    :forensic_log     # List: Stores last N feelings for autopsy
  ]

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    node_id = get_opt(opts, :node_id)
    target_pid = get_opt(opts, :target_pid)
    
    # Initial sampling rate: 1s
    sampling_rate = 1000
    
    Logger.info("PhysiologySentinel attached to OS PID #{target_pid} for Node #{node_id}")
    
    Process.send_after(self(), :grip_reality, sampling_rate)

    {:ok, %__MODULE__{
      node_id: node_id,
      target_pid: target_pid,
      sampling_rate: sampling_rate,
      last_metrics: nil,
      forensic_log: []
    }}
  end

  @impl true
  def handle_info(:grip_reality, state) do
    # 1. Grip Reality (Read /proc)
    case read_proc_stats(state.target_pid) do
      {:ok, current_metrics} ->
        # 2. Calculate Deltas
        deltas = calculate_deltas(current_metrics, state.last_metrics, state.sampling_rate)
        
        # 3. Transmute (Physics)
        feelings = Alchemist.transmute_os_metrics(deltas)
        
        # 4. Update Node
        update_node(state.node_id, feelings, deltas)
        
        # 5. Forensic Logging: Keep last 10 feelings for autopsy
        new_log = Enum.take([feelings.effect | state.forensic_log], 10)
        
        # 6. Dynamic Loop
        Process.send_after(self(), :grip_reality, state.sampling_rate)
        {:noreply, %{state | last_metrics: current_metrics, forensic_log: new_log}}

      {:error, :process_not_found} ->
         Logger.warning("[PhysiologySentinel] Target PID #{state.target_pid} vanished. Executing Necrosis Protocol.")
         
         # NECROSIS PROTOCOL: Death Signal Detected (Section 8.1)
         # 1. Capture Final State (Historical Forensic Context)
         exit_code = determine_exit_code(state)
         final_buffer = state.forensic_log
         
         # 2. Trigger Autopsy via TrackingAgent (Section 8.2)
         case Registry.lookup(CMS.NodeRegistry, {:tracking_agent, state.node_id}) do
           [{tracker_pid, _}] ->
             GenServer.cast(tracker_pid, {:execute_autopsy, exit_code, final_buffer})
             Logger.info("[PhysiologySentinel] Autopsy triggered for Node #{state.node_id}")
           [] ->
             Logger.warning("[PhysiologySentinel] No TrackingAgent found for Node #{state.node_id}")
         end
         
         # 3. Sentinel Terminates (Resource Release - Section 8.2)
         {:stop, :normal, state}
         
      {:error, _reason} ->
         # Retry
         Process.send_after(self(), :grip_reality, state.sampling_rate)
         {:noreply, state}
    end
  end

  # --- Internals ---

  defp read_proc_stats(pid) do
    # Check if /proc/[pid] exists
    if File.exists?("/proc/#{pid}/stat") do
      try do
        # GRIP: Read raw inputs
        stat = File.read!("/proc/#{pid}/stat")
        status = File.read!("/proc/#{pid}/status")
        
        {state_code, cpu_ticks, rss_pages} = parse_stat(stat)
        
        # Basic Net simulation (since we can't easily isolate per-process net without cgroups/ns)
        # We will poll global net devs and apportion, or mock specific IO based on /proc/[pid]/io if available
        # For Phase 3 implementation fidelity, we check /proc/[pid]/io
        io_stats = read_proc_io(pid)

        # Normalize metrics
        total_mem_kb = parse_status_mem(status)
        
        {:ok, %{
          timestamp: System.monotonic_time(:millisecond),
          state: state_code,
          utime: cpu_ticks, # User time ticks
          rss: rss_pages,
          mem_kb: total_mem_kb,
          read_bytes: io_stats.read_bytes,
          write_bytes: io_stats.write_bytes
        }}
      rescue
        _ -> {:error, :read_failed}
      end
    else
      {:error, :process_not_found}
    end
  end

  defp parse_stat(content) do
    # /proc/[pid]/stat format: pid (name) state ppid ...
    parts = String.split(content)
    # 3rd field is State
    state = Enum.at(parts, 2)
    # 14th is utime, 15th is stime (0-indexed: 13, 14)
    utime = String.to_integer(Enum.at(parts, 13))
    stime = String.to_integer(Enum.at(parts, 14))
    # 24th is RSS pages (0-indexed: 23)
    rss = String.to_integer(Enum.at(parts, 23))
    
    {state, utime + stime, rss}
  end

  defp parse_status_mem(content) do
    regex = ~r/VmRSS:\s+(\d+)\s+kB/
    case Regex.run(regex, content) do
      [_, kb_str] -> String.to_integer(kb_str)
      _ -> 0
    end
  end
  
  defp read_proc_io(pid) do
    path = "/proc/#{pid}/io"
    if File.exists?(path) do
       content = File.read!(path)
       r_bytes = get_io_val(content, "read_bytes")
       w_bytes = get_io_val(content, "write_bytes")
       %{read_bytes: r_bytes, write_bytes: w_bytes}
    else
       %{read_bytes: 0, write_bytes: 0}
    end
  end
  
  defp get_io_val(content, key) do
    case Regex.run(~r/#{key}:\s+(\d+)/, content) do
      [_, val] -> String.to_integer(val)
      _ -> 0
    end
  end

  defp calculate_deltas(current, nil, _rate), do: %{
      cpu_usage: 0.0,
      ram_bytes: current.mem_kb * 1024,
      state: current.state,
      net_in_delta: 0,
      net_out_delta: 0,
      jitter_sec: 0.0
  }

  defp calculate_deltas(current, last, rate_ms) do
    # Time delta in seconds
    dt_sec = (current.timestamp - last.timestamp) / 1000.0
    dt_sec = if dt_sec <= 0, do: 1.0, else: dt_sec
    
    # Jitter Calculation: How far did we drift from the target sampling rate?
    target_interval_sec = rate_ms / 1000.0
    jitter_sec = abs(dt_sec - target_interval_sec)
    
    # CPU Delta: ticks / Hz (usually 100) / time
    # This is a Rough Estimate.
    cpu_delta = (current.utime - last.utime) 
    # Assume 100Hz clock for simplicity
    cpu_usage = (cpu_delta / 100.0) / dt_sec * 100.0
    
    # IO (Net) simulation: read_bytes -> net_in, write_bytes -> net_out for process abstraction
    in_rate = (current.read_bytes - last.read_bytes) / dt_sec
    out_rate = (current.write_bytes - last.write_bytes) / dt_sec

    %{
      cpu_usage: cpu_usage,
      ram_bytes: current.mem_kb * 1024,
      state: current.state,
      net_in_delta: in_rate,
      net_out_delta: out_rate,
      jitter_sec: jitter_sec
    }
  end

  defp update_node(node_id, feelings, raw_deltas) do
    case Registry.lookup(CMS.NodeRegistry, node_id) do
      [{pid, _}] ->
         # 1. Update Physiological Chamber (Body)
         GenServer.cast(pid, {:update_physics, feelings, raw_deltas})

         # 2. Update Transfer Ratio Edge (Tail)
         # Ratio = Output / Input
         # Handle div/0 gracefully by clamping denominator
         input = max(raw_deltas.net_in_delta, 0.0001) 
         ratio = raw_deltas.net_out_delta / input
         
         # The Spec requires updating NodeTail.communication_edges.
         # We instruct the NodeActor to upsert an edge representing this IO Ratio.
         # Target: "os:network" or similar abstraction since we don't have per-connection stats here.
         GenServer.cast(pid, {:update_communication_edge, "os:network", ratio})
         
         # 3. Signal Pain (Antenna Boost)
         # "If Stress > 0.8, trigger Antenna Boost."
         if feelings.stress > 0.8 do
            excess_stress = feelings.stress - 0.8
            boost_multiplier = 1.0 + (excess_stress * 5.0)
            GenServer.cast(pid, {:boost_antenna, boost_multiplier}) 
            
            # Spec 7.2: Trigger Archival on Sentinel Event
            case Registry.lookup(CMS.NodeRegistry, {:tracking_agent, node_id}) do
               [{t_pid, _}] -> GenServer.cast(t_pid, :trigger_archival)
               _ -> :ok
            end
         end
         
      [] -> :ok
    end
  end

  defp determine_exit_code(state) do
    # Inference Protocol: Guessing death reason from last known physiological state
    last_metrics = state.last_metrics
    
    cond do
      is_nil(last_metrics) -> -1
      
      # OOM Heuristic: High RAM and high Stress
      (Map.get(last_metrics, :mem_kb, 0) * 1024) > (500 * 1024 * 1024) -> 
        Logger.info("[PhysiologySentinel] Inferred death: OOM Kill (SIGKILL 137)")
        137
        
      # Signal SIGTERM Heuristic: Clean state but vanished
      last_metrics.state == "S" -> 
        Logger.info("[PhysiologySentinel] Inferred death: Graceful Shutdown (SIGTERM 143)")
        143
        
      # Abort/Crash Heuristic: Process was in high-stress Uninterruptible Sleep (D)
      last_metrics.state == "D" -> 
        Logger.info("[PhysiologySentinel] Inferred death: Unrecoverable IO/Kernel Error (SIGABRT 134)")
        134

      true -> -1
    end
  end

  defp get_opt(opts, key) when is_list(opts), do: Keyword.fetch!(opts, key)
  defp get_opt(opts, key) when is_map(opts), do: Map.fetch!(opts, key)
end
