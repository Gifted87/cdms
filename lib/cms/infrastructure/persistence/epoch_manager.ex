defmodule CMS.EpochManager do
  use GenServer
  require Logger

  @moduledoc """
  Manages the lifecycle of Epoch Log files and the Mnesia index.

  Responsibilities:
  1. Creates new Epoch Log files (rotation).
  2. Updates Mnesia with metadata (start_time, end_time, path).
  3. Ensures proper closure of old logs.
  """

  # Mnesia Table Definition
  @table_name :epoch_log_index
  @nodes_table :nodes_table
  @vector_index :vector_index

  @log_dir "priv/data/epochs" # Keep for fallback or reference, though log_dir/0 overrides
  @rotation_interval :timer.hours(1)
  @max_size_bytes 100 * 1024 * 1024 # 100MB
  
  # Dynamic Log Path Resolution
  defp log_dir do
    case System.get_env("ACMS_DATA_DIR") do
      nil -> "priv/data/epochs"
      dir -> Path.join(dir, "epochs")
    end
  end

  defstruct [:current_file_path, :current_log_id, :file_handle, :bytes_written, :rotation_timer]

  # API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def get_active_handle do
    GenServer.call(__MODULE__, :get_active_handle)
  end

  def notify_bytes_written(count) do
    GenServer.cast(__MODULE__, {:bytes_written, count})
  end

  def rotate_log do
    GenServer.call(__MODULE__, :rotate)
  end

  def list_epoch_files do
    GenServer.call(__MODULE__, :list_files)
  end

  # Callbacks

  @impl true
  def init(:ok) do
    # Initialize Mnesia Schema and Directory
    init_mnesia()
    File.mkdir_p!(log_dir())


    # Open first log
    state = start_new_epoch()

    # Schedule time-based rotation
    timer = Process.send_after(self(), :time_rotate, @rotation_interval)

    {:ok, %{state | rotation_timer: timer}}
  end

  @impl true
  def handle_call(:get_active_handle, _from, state) do
    {:reply, state.file_handle, state}
  end

  @impl true
  def handle_call(:rotate, _from, state) do
    new_state = rotate_epoch(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:list_files, _from, state) do
    # Fetch all epochs from Mnesia, sorted by start time
    files = :mnesia.transaction(fn ->
      :mnesia.match_object({@table_name, :_, :_, :_, :_})
    end)
    
    sorted_paths = case files do
      {:atomic, list} ->
        list
        |> Enum.sort_by(fn {_, _, start_time, _, _} -> start_time end, DateTime)
        |> Enum.map(fn {_, _, _, _, path} -> path end)
      _ -> []
    end
    
    {:reply, sorted_paths, state}
  end

  @impl true
  def handle_cast({:bytes_written, count}, state) do
    new_bytes = state.bytes_written + count
    if new_bytes >= @max_size_bytes do
      Logger.info("EpochManager: Max size reached. Rotating log.")
      {:noreply, rotate_epoch(state)}
    else
      {:noreply, %{state | bytes_written: new_bytes}}
    end
  end

  @impl true
  def handle_info(:time_rotate, state) do
    Logger.info("EpochManager: Time interval reached. Rotating log.")
    new_state = rotate_epoch(state)
    timer = Process.send_after(self(), :time_rotate, @rotation_interval)
    {:noreply, %{new_state | rotation_timer: timer}}
  end

  # Internals

  defp init_mnesia do
    # 1. Get Directory from Config
    raw_dir = Application.get_env(:mnesia, :dir) || "priv/data/mnesia_store"

    # FIX: Convert binary string to charlist for Erlang Mnesia compatibility.
    # config.exs usually supplies a binary string, which causes :function_clause errors in Mnesia.
    mnesia_dir = if is_binary(raw_dir), do: String.to_charlist(raw_dir), else: raw_dir

    # 2. Ensure the directory exists on disk (using binary path for Elixir File module)
    File.mkdir_p!(to_string(mnesia_dir))

    # 3. Update Application Env to force Mnesia to use this Charlist path
    Application.put_env(:mnesia, :dir, mnesia_dir)

    nodes = [Node.self()]

    # 4. Stop Mnesia to perform schema operations
    :mnesia.stop()

    # 5. Create Schema
    case :mnesia.create_schema(nodes) do
      :ok ->
        Logger.info("Mnesia schema created on disk at #{mnesia_dir}.")
      {:error, {_, {:already_exists, _}}} ->
        Logger.info("Mnesia schema already exists.")
      error ->
        Logger.error("Mnesia create_schema failed: #{inspect(error)}")
    end

    # 6. Start Mnesia
    :mnesia.start()

    # 7. Create the Table
    case :mnesia.create_table(@table_name, [
      attributes: [:id, :start_time, :end_time, :file_path],
      disc_copies: nodes
    ]) do
      {:atomic, :ok} -> Logger.info("Mnesia table #{@table_name} created.")
      {:aborted, {:already_exists, _}} -> :ok
      other -> Logger.error("Mnesia create_table failed: #{inspect(other)}")
    end

    # 8. Create Nodes Table
    case :mnesia.create_table(@nodes_table, [
      attributes: [:uuid, :path_hash, :parent_uuid, :head_data, :body_data, :tail_data, :chrono_stack, :provenance, :antenna_data],
      disc_copies: nodes
    ]) do
      {:atomic, :ok} -> Logger.info("Mnesia table #{@nodes_table} created.")
      {:aborted, {:already_exists, _}} -> :ok
      other -> Logger.error("Mnesia create_table nodes_table failed: #{inspect(other)}")
    end

    # 9. Create Vector Index Table
    case :mnesia.create_table(@vector_index, [
      attributes: [:id, :vector],
      disc_copies: nodes,
      type: :ordered_set # For auto-increment simulation if needed
    ]) do
      {:atomic, :ok} -> Logger.info("Mnesia table #{@vector_index} created.")
      {:aborted, {:already_exists, _}} -> :ok
      other -> Logger.error("Mnesia create_table vector_index failed: #{inspect(other)}")
    end
  end

  defp start_new_epoch do
    id = UUID.uuid4()
    timestamp = DateTime.utc_now()
    filename = "epoch_#{DateTime.to_iso8601(timestamp) |> String.replace(":", "-")}_#{id}.jsonl"
    path = Path.join(log_dir(), filename)

    {:ok, handle} = File.open(path, [:append, :utf8])

    :mnesia.transaction(fn ->
      :mnesia.write({@table_name, id, timestamp, :infinity, path})
    end)

    Logger.info("Started new Epoch Log: #{path}")

    %__MODULE__{
      current_file_path: path,
      current_log_id: id,
      file_handle: handle,
      bytes_written: 0
    }
  end

  defp rotate_epoch(state) do
    File.close(state.file_handle)

    now = DateTime.utc_now()
    old_id = state.current_log_id

    :mnesia.transaction(fn ->
      [{_tag, _id, start, _end, path}] = :mnesia.read(@table_name, old_id)
      :mnesia.write({@table_name, old_id, start, now, path})
    end)

    start_new_epoch()
  end
end
