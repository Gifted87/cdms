defmodule CMS.LogAppender do
  use GenServer
  require Logger

  @moduledoc """
  High-throughput append-only logger for the CMS.

  Receives:
  1. Node Snapshots (Create/Update) - CRITICAL: Stores full state for Chrono Stack.
  2. Hebbian Updates (Link weights)
  3. System/Failure Events (Query failures, etc.)

  Writes to the active file handle provided by EpochManager.
  """

  @buffer_size 50 # Flush after 50 items
  @flush_interval 1000 # Or every 1 second

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # Client API

  @doc """
  Logs a full Node snapshot.
  Type: :node_created | :node_updated | :node_decayed

  CRITICAL PATCH: Now accepts the *full* CMS.Node.t() for all updates,
  ensuring the log is a full Chrono Stack history.
  """
  @spec append_node_event(CMS.Node.id(), atom(), CMS.Node.t() | map()) :: :ok
  def append_node_event(node_id, type, %CMS.Node{} = full_node) when type in [:node_created, :node_updated, :node_migrated] do
    GenServer.cast(__MODULE__, {:log, %{
      timestamp: DateTime.utc_now(),
      entity: :node,
      id: node_id,
      type: type,
      # Store the *entire node struct* for full Chrono Stack auditability (Plan Sec 9)
      data: full_node
    }})
  end

  # Special case for node_fired and node_decayed, which are state changes but don't require the full struct to be logged.
  def append_node_event(node_id, type, data) when type in [:node_fired, :node_decayed] and is_map(data) do
    GenServer.cast(__MODULE__, {:log, %{
      timestamp: DateTime.utc_now(),
      entity: :node,
      id: node_id,
      type: type,
      data: data
    }})
  end

  @doc """
  Logs a batch of Hebbian weight updates.
  """
  def append_hebbian_updates(updates) do
    GenServer.cast(__MODULE__, {:log, %{
      timestamp: DateTime.utc_now(),
      entity: :hebbian,
      data: updates
    }})
  end

  # --- NEW: System Event/Failure Reporting API ---
  @doc """
  Logs a critical system event, such as a query failure or system congestion.
  """
  @spec append_system_event(atom(), map()) :: :ok
  def append_system_event(type, data) do
    GenServer.cast(__MODULE__, {:log, %{
      timestamp: DateTime.utc_now(),
      entity: :system,
      type: type,
      data: data
    }})
  end

  # Server Callbacks
  # ... (init, handle_cast, handle_info, flush_buffer remain unchanged)

  @impl true
  def init(:ok) do
    Process.send_after(self(), :flush, @flush_interval)
    {:ok, %{buffer: []}}
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    new_buffer = [entry | state.buffer]
    if length(new_buffer) >= @buffer_size do
      flush_buffer(new_buffer)
      {:noreply, %{buffer: []}}
    else
      {:noreply, %{buffer: new_buffer}}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    unless Enum.empty?(state.buffer) do
      flush_buffer(state.buffer)
    end
    Process.send_after(self(), :flush, @flush_interval)
    {:noreply, %{buffer: []}}
  end

  defp flush_buffer(buffer) do
    # Get handle from EpochManager (Step 7.1)
    file = CMS.EpochManager.get_active_handle()

    # 1. Reverse buffer (since we prepended)
    # 2. Serialize to JSONL
    data_chunk =
      buffer
      |> Enum.reverse()
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    # 3. Write newline at end
    blob = data_chunk <> "\n"

    case IO.write(file, blob) do
      :ok ->
        CMS.EpochManager.notify_bytes_written(byte_size(blob))
      {:error, reason} ->
        Logger.error("LogAppender failed to write to epoch log: #{inspect(reason)}")
        # In prod, we might buffer back or crash to ensure no data loss
    end
  end
end
