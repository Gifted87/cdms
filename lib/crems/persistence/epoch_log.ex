defmodule CREMS.Persistence.EpochLog do
  @moduledoc """
  Long-term cold storage for CREMS Ghost Node forensic data.
  
  Stores archived ChronoStacks from terminated/crashed processes,
  enabling forensic queries like:
  - "Show me all nodes that died with Exit Code 137 (OOM) in the last hour"
  - "Retrieve the full history of node X after it crashed"
  
  Storage Strategy:
  - File-based in priv/data/crems_epoch_logs/
  - Daily directories for organization
  - ETS index for fast lookups
  - Binary serialization via :erlang.term_to_binary/1
  """

  use GenServer
  require Logger

  @default_base_path "priv/data/crems_epoch_logs"

  defstruct [
    :base_path,
    :index_table  # ETS table for metadata index
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Archives a ghost node's ChronoStack to cold storage.
  
  Metadata should include:
  - node_id: String
  - exit_code: Integer
  - death_time: DateTime.t()
  - tags: List of semantic tags
  - process_role: String
  """
  def archive_ghost(node_id, chrono_stack, metadata) do
    GenServer.call(__MODULE__, {:archive, node_id, chrono_stack, metadata})
  end

  @doc """
  Query archived nodes by exit code within a time range.
  
  Returns list of %{node_id, exit_code, death_time, archive_path, tags}
  """
  def query_by_exit_code(exit_code, time_range \\ :all) do
    GenServer.call(__MODULE__, {:query_exit_code, exit_code, time_range})
  end

  @doc """
  Retrieve a specific node's archived ChronoStack by node_id.
  """
  def query_by_node_id(node_id) do
    GenServer.call(__MODULE__, {:query_node, node_id})
  end

  @doc """
  Query all archived nodes within a time range.
  """
  def query_by_time_range(start_time, end_time) do
    GenServer.call(__MODULE__, {:query_time_range, start_time, end_time})
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    base_path = Keyword.get(opts, :base_path, @default_base_path)
    
    # Ensure directory structure exists
    archives_path = Path.join(base_path, "archives")
    File.mkdir_p!(archives_path)
    
    # Create ETS index table (persistent across restarts via disk-based recovery)
    index_table = :ets.new(:epoch_log_index, [:set, :public, :named_table])
    
    # Load existing index from disk if it exists
    load_index_from_disk(base_path, index_table)
    
    Logger.info("[EpochLog] Initialized at #{base_path}")
    
    {:ok, %__MODULE__{
      base_path: base_path,
      index_table: index_table
    }}
  end

  @impl true
  def handle_call({:archive, node_id, chrono_stack, metadata}, _from, state) do
    result = perform_archive(node_id, chrono_stack, metadata, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:query_exit_code, exit_code, time_range}, _from, state) do
    results = perform_query_by_exit_code(exit_code, time_range, state)
    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call({:query_node, node_id}, _from, state) do
    result = perform_query_by_node_id(node_id, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:query_time_range, start_time, end_time}, _from, state) do
    results = perform_query_by_time_range(start_time, end_time, state)
    {:reply, {:ok, results}, state}
  end

  # --- Internal Logic ---

  defp perform_archive(node_id, chrono_stack, metadata, state) do
    death_time = Map.get(metadata, :death_time, DateTime.utc_now())
    exit_code = Map.get(metadata, :exit_code, -1)
    tags = Map.get(metadata, :tags, [])
    process_role = Map.get(metadata, :process_role, "unknown")
    
    # Generate archive path
    date_dir = Calendar.strftime(death_time, "%Y-%m-%d")
    archives_dir = Path.join([state.base_path, "archives", date_dir])
    File.mkdir_p!(archives_dir)
    
    # Filename: node_<short_id>_exit_<code>_<timestamp>.bin
    short_id = String.slice(node_id, 0..7)
    timestamp = DateTime.to_unix(death_time)
    filename = "node_#{short_id}_exit_#{exit_code}_#{timestamp}.bin"
    archive_path = Path.join(archives_dir, filename)
    
    # Serialize and write
    try do
      binary_data = :erlang.term_to_binary(%{
        node_id: node_id,
        chrono_stack: chrono_stack,
        metadata: metadata
      }, [:compressed])
      
      File.write!(archive_path, binary_data)
      
      # Update index
      index_entry = %{
        node_id: node_id,
        exit_code: exit_code,
        death_time: death_time,
        archive_path: archive_path,
        tags: tags,
        process_role: process_role
      }
      
      :ets.insert(state.index_table, {node_id, index_entry})
      
      # Persist index to disk
      persist_index_to_disk(state.base_path, state.index_table)
      
      Logger.info("[EpochLog] Archived node #{node_id} (exit: #{exit_code}) to #{archive_path}")
      {:ok, archive_path}
    rescue
      e ->
        Logger.error("[EpochLog] Failed to archive node #{node_id}: #{inspect(e)}")
        {:error, :archive_failed}
    end
  end

  defp perform_query_by_exit_code(exit_code, time_range, state) do
    :ets.tab2list(state.index_table)
    |> Enum.map(fn {_key, entry} -> entry end)
    |> Enum.filter(fn entry -> entry.exit_code == exit_code end)
    |> apply_time_filter(time_range)
  end

  defp perform_query_by_node_id(node_id, state) do
    case :ets.lookup(state.index_table, node_id) do
      [{^node_id, entry}] ->
        # Load full archive from disk
        load_archive_from_disk(entry.archive_path)
      [] ->
        {:error, :not_found}
    end
  end

  defp perform_query_by_time_range(start_time, end_time, state) do
    :ets.tab2list(state.index_table)
    |> Enum.map(fn {_key, entry} -> entry end)
    |> Enum.filter(fn entry ->
      DateTime.compare(entry.death_time, start_time) in [:gt, :eq] and
      DateTime.compare(entry.death_time, end_time) in [:lt, :eq]
    end)
  end

  defp apply_time_filter(entries, :all), do: entries
  defp apply_time_filter(entries, {start_time, end_time}) do
    Enum.filter(entries, fn entry ->
      DateTime.compare(entry.death_time, start_time) in [:gt, :eq] and
      DateTime.compare(entry.death_time, end_time) in [:lt, :eq]
    end)
  end

  defp load_archive_from_disk(path) do
    if File.exists?(path) do
      try do
        binary = File.read!(path)
        archive = :erlang.binary_to_term(binary)
        {:ok, archive}
      rescue
        e ->
          Logger.error("[EpochLog] Failed to load archive from #{path}: #{inspect(e)}")
          {:error, :load_failed}
      end
    else
      {:error, :not_found}
    end
  end

  defp persist_index_to_disk(base_path, table) do
    index_path = Path.join(base_path, "index.bin")
    entries = :ets.tab2list(table)
    binary = :erlang.term_to_binary(entries, [:compressed])
    File.write!(index_path, binary)
  end

  defp load_index_from_disk(base_path, table) do
    index_path = Path.join(base_path, "index.bin")
    
    if File.exists?(index_path) do
      try do
        binary = File.read!(index_path)
        entries = :erlang.binary_to_term(binary)
        Enum.each(entries, fn entry -> :ets.insert(table, entry) end)
        Logger.info("[EpochLog] Loaded #{length(entries)} index entries from disk")
      rescue
        e ->
          Logger.warning("[EpochLog] Failed to load index from disk: #{inspect(e)}")
      end
    end
  end
end
