defmodule CREMS.Agents.BeamSentinel do
  use GenServer
  require Logger
  alias CREMS.Physics.Alchemist

  @moduledoc """
  The Ghost Introspector: Monitors a BEAM process and transmutes its runtime stats into Feelings.
  """

  defstruct [
    :node_id,
    :target_pid,      # PID (BEAM PID)
    :monitor_ref,
    :sampling_rate,
    :last_metrics,
    :forensic_log
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
    
    # Monitor to detect death immediately
    ref = Process.monitor(target_pid)
    sampling_rate = 1000

    Logger.info("BeamSentinel attached to BEAM PID #{inspect(target_pid)} for Node #{node_id}")
    
    # RIGOROUS: Enable Transfer Ratio Tracking via sys.statistics
    try do
      :sys.statistics(target_pid, true)
    rescue
      _ -> Logger.warning("BeamSentinel Warning: Target #{inspect(target_pid)} does not support sys stats.")
    end
    
    Process.send_after(self(), :grip_reality, sampling_rate)

    {:ok, %__MODULE__{
      node_id: node_id,
      target_pid: target_pid,
      monitor_ref: ref,
      sampling_rate: sampling_rate,
      last_metrics: nil,
      forensic_log: []
    }}
  end

  @impl true
  def handle_info(:grip_reality, state) do
    # 1. Grip Reality (Process.info + sys.statistics)
    # RIGOROUS: We need both basic info and message counters
    case Process.info(state.target_pid, [:message_queue_len, :total_heap_size, :reductions, :status]) do
      nil -> {:noreply, state} # handled by DOWN
         
      info_list ->
         base_metrics = Map.new(info_list)
         sys_metrics = get_sys_stats(state.target_pid)
         
         current_metrics = Map.merge(base_metrics, sys_metrics)
         timestamp = System.monotonic_time(:millisecond)
         
         # 2. Calculate Deltas
         deltas = calculate_deltas(current_metrics, state.last_metrics, timestamp)
         
         # 3. Transmute
         feelings = Alchemist.transmute_beam_metrics(deltas)
         
         # 4. Update Node
         update_node(state.node_id, feelings, deltas)
         
         # 5. Forensic Logging
         new_log = Enum.take([feelings.effect | state.forensic_log], 10)
         
         Process.send_after(self(), :grip_reality, state.sampling_rate)
         {:noreply, %{state | last_metrics: Map.put(current_metrics, :timestamp, timestamp), forensic_log: new_log}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
     Logger.warning("[BeamSentinel] Target BEAM process died. Reason: #{inspect(reason)}. Executing Necrosis Protocol.")
     
     # NECROSIS PROTOCOL: Death Signal Detected (Section 8.1)
     
     # 1. Capture Final State
     # Convert BEAM reason to a numeric exit code for the autopsy protocol
     exit_code = case reason do
       :normal -> 0
       :shutdown -> 0
       {:shutdown, _} -> 0
       _ -> -1 # Any other reason is a crash
     end

     # Final buffer from last known stats (Historical Forensic Context)
     final_buffer = state.forensic_log
     
     # 2. Trigger Autopsy via TrackingAgent (Section 8.2)
     case Registry.lookup(CMS.NodeRegistry, {:tracking_agent, state.node_id}) do
       [{tracker_pid, _}] ->
         GenServer.cast(tracker_pid, {:execute_autopsy, exit_code, final_buffer})
         Logger.info("[BeamSentinel] Autopsy triggered for Node #{state.node_id}")
       [] ->
         Logger.warning("[BeamSentinel] No TrackingAgent found for Node #{state.node_id}")
     end
     
     # 3. Sentinel Terminates (Resource Release - Section 8.2)
     {:stop, :normal, state}
  end

  # --- Internals ---
  
  defp get_sys_stats(pid) do
    try do
       {:ok, stats} = :sys.statistics(pid, :get)
       # stats list: [start_time: _, current_time: _, reductions: _, messages_in: X, messages_out: Y]
       %{
         msgs_in: Keyword.get(stats, :messages_in, 0),
         msgs_out: Keyword.get(stats, :messages_out, 0)
       }
    rescue
       _ -> %{msgs_in: 0, msgs_out: 0}
    end
  end

  defp calculate_deltas(current, nil, _ts) do
     Map.merge(current, %{
        reductions_delta: 0,
        net_in_delta: 0,
        net_out_delta: 0
     })
  end

  defp calculate_deltas(current, last, ts) do
     dt_sec = (ts - last.timestamp) / 1000.0
     dt_sec = if dt_sec <= 0, do: 1.0, else: dt_sec
     
     red_delta = (current[:reductions] - last[:reductions]) / dt_sec
     
     # Calculate Transfer Ratio components (Messages/sec)
     in_delta = (current.msgs_in - last.msgs_in) / dt_sec
     out_delta = (current.msgs_out - last.msgs_out) / dt_sec
     
     Map.merge(current, %{
        reductions_delta: red_delta,
        net_in_delta: in_delta, 
        net_out_delta: out_delta 
        # Note: net_in/out mapped to message counts for Alchemist compatibility? 
        # Alchemist expects 'net_in_delta' for Agility bonus, which works fine with msg counts.
     })
  end

  defp update_node(node_id, feelings, raw_deltas) do
    case Registry.lookup(CMS.NodeRegistry, node_id) do
       [{pid, _}] ->
          # 1. Update Physiology
          GenServer.cast(pid, {:update_physics, feelings, raw_deltas})
          
          # 2. Update Transfer Ratio (Rigorous)
          input = max(Map.get(raw_deltas, :net_in_delta, 0.0001), 0.0001)
          output = Map.get(raw_deltas, :net_out_delta, 0.0)
          ratio = output / input
          
          GenServer.cast(pid, {:update_communication_edge, "beam:link", ratio})

          # Spec 7.2: Trigger Archival on Sentinel Event (Significant Stress or Death)
          if feelings.stress > 0.8 or feelings.state == :terminated do
             case Registry.lookup(CMS.NodeRegistry, {:tracking_agent, node_id}) do
                [{t_pid, _}] -> GenServer.cast(t_pid, :trigger_archival)
                _ -> :ok
             end
          end
          
       [] -> :ok
    end
  end

  defp get_opt(opts, key) when is_list(opts), do: Keyword.fetch!(opts, key)
  defp get_opt(opts, key) when is_map(opts), do: Map.fetch!(opts, key)
end
