defmodule CMS.Symbiosis.ProcessLinker do
  @moduledoc """
  The Definition Linker: Bridges Anatomy (CDMS Files) and Physiology (CREMS Processes).
  
  Periodically scans the host system for running processes, identifies their
  source executables, and establishes `:defines` edges in the CDMS.
  """
  use GenServer
  require Logger

  @sweep_interval :timer.seconds(30)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_sweep()
    {:ok, %{last_sweep: nil}}
  end

  def handle_info(:sweep, state) do
    Logger.info("ProcessLinker: Starting physiological sweep...")
    active_pids()
    |> Enum.each(&link_process/1)
    
    schedule_sweep()
    {:noreply, %{state | last_sweep: DateTime.utc_now()}}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  # --- Linkage Logic ---

  defp link_process(pid) do
    case get_executable_path(pid) do
      {:ok, path} ->
        # Look up the Anatomy Node (CDMS) for this path
        case CMS.SymbolicIndex.get_node_by_path(path) do
          {:ok, cdms_node_pid} ->
            establish_link(pid, path, cdms_node_pid)
          _ ->
            # Node not found in CDMS, likely ignored or not yet ingested
            :ok
        end
      _ -> :ok
    end
  end

  defp establish_link(os_pid, path, cdms_node_pid) do
    # 1. Get the CDMS Node UUID
    case GenServer.call(cdms_node_pid, :get_state_snapshot) do
      {:ok, %CMS.Node{id: cdms_uuid}} ->
        Logger.debug("ProcessLinker: Link established PID #{os_pid} -> #{path} (#{cdms_uuid})")
        
        # Broadcast the link for real-time visualization
        Phoenix.PubSub.broadcast(CMS.PubSub, "cdms:symbiosis", {:process_link, os_pid, cdms_uuid})
        
        # Physiological activity boosts activation (Pulse)
        # We use a specific pulse strength to signal active execution
        GenServer.cast(cdms_node_pid, :fire)
      _ -> :ok
    end
  rescue
    e -> Logger.warning("ProcessLinker: Failed to establish link for PID #{os_pid}: #{inspect(e)}")
  end

  # --- OS Specifics (/proc scan) ---

  defp active_pids do
    case File.ls("/proc") do
      {:ok, items} ->
        items
        |> Enum.filter(&Regex.match?(~r/^\d+$/, &1))
        |> Enum.map(&String.to_integer/1)
      _ -> []
    end
  end

  defp get_executable_path(pid) do
    link_path = "/proc/#{pid}/exe"
    case File.read_link(link_path) do
      {:ok, path} -> {:ok, path}
      _ -> {:error, :not_accessible}
    end
  end
end
