defmodule CREMS.Agents.HardwareSentinel do
  use GenServer
  require Logger
  alias CREMS.Physics.Alchemist

  @moduledoc """
  The hardware-focused sentinel: Processes system-wide telemetry into feelings.
  """

  defstruct [
    :node_id,
    :type,           # :cpu, :ram, :storage
    :sampling_rate,
    :last_metrics
  ]

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    type = Keyword.fetch!(opts, :type)
    sampling_rate = Keyword.get(opts, :sampling_rate, 2000)

    Process.send_after(self(), :pulse, 100) # Fast start

    {:ok, %__MODULE__{
      node_id: node_id,
      type: type,
      sampling_rate: sampling_rate,
      last_metrics: nil
    }}
  end

  @impl true
  def handle_info(:pulse, state) do
    metrics = read_hardware_metrics(state.type)
    
    # Calculate feelings
    feelings = Alchemist.transmute_hardware_metrics(metrics)
    
    # Update Node
    case Registry.lookup(CMS.NodeRegistry, state.node_id) do
      [{pid, _}] -> 
        GenServer.cast(pid, {:update_physics, feelings, metrics})
      [] -> :ok
    end

    Process.send_after(self(), :pulse, state.sampling_rate)
    {:noreply, %{state | last_metrics: metrics}}
  end

  # --- Internals ---

  defp read_hardware_metrics(:cpu) do
    # Simply reading /proc/loadavg for now as a proxy for 'usage' to avoid delta math in first pass
    # Or actually, let's do real usage eventually. For now, LoadAvg 1m.
    {load, _} = 
      case File.read("/proc/loadavg") do
        {:ok, content} -> 
           [l1, _, _ | _] = String.split(content)
           {l1_f, _} = Float.parse(l1)
           # Normalize: 1.0 load per core is 100%?
           # We'll assume a 4 core machine for normalization base if unknown
           {l1_f * 25.0, nil} 
        _ -> {0.0, nil}
      end

    # iowait from /proc/stat (aggregate)
    iowait = case File.read("/proc/stat") do
      {:ok, content} ->
        line = content |> String.split("\n") |> List.first()
        parts = String.split(line, " ", trim: true)
        # iowait is the 5th tick value (0-indexed: 4) after "cpu" (0)
        # Format: cpu user nice system idle iowait ...
        # [0]=cpu, [1]=user, [2]=nice, [3]=system, [4]=idle, [5]=iowait
        case Enum.at(parts, 5) do
          nil -> 0.0
          val -> 
            io_ticks = String.to_integer(val)
            min(10.0, io_ticks / 1000000.0) # Arbitrary scaling for proxy
        end
      _ -> 0.0
    end

    %{type: :cpu, cpu_usage: min(100.0, load), iowait: iowait}
  end

  defp read_hardware_metrics(:ram) do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        total = extract_mem(content, "MemTotal")
        _free = extract_mem(content, "MemFree")
        avail = extract_mem(content, "MemAvailable")
        
        used = total - avail
        
        swap_total = extract_mem(content, "SwapTotal")
        swap_free = extract_mem(content, "SwapFree")
        swap_used = swap_total - swap_free

        %{
          type: :ram,
          total_kb: total,
          used_kb: used,
          total_swap_kb: swap_total,
          used_swap_kb: swap_used
        }
      _ ->
        %{type: :ram, total_kb: 1024, used_kb: 0, total_swap_kb: 0, used_swap_kb: 0}
    end
  end

  defp read_hardware_metrics(:storage) do
    # Parsing df -B1 /
    output = :os.cmd('df -B1 / | tail -n 1') |> to_string()
    parts = String.split(output, " ", trim: true)
    
    # Filesystem Size Used Avail Use% Mounted
    total = Enum.at(parts, 1) |> String.to_integer()
    used = Enum.at(parts, 2) |> String.to_integer()
    
    %{type: :storage, total: total, used: used}
  end

  defp extract_mem(content, key) do
    case Regex.run(~r/#{key}:\s+(\d+)\s+kB/, content) do
      [_, val] -> String.to_integer(val)
      _ -> 0
    end
  end
end
