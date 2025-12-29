defmodule CMS.SymbolicIndex do
  use GenServer
  require Logger

  @moduledoc """
  Mode A: The Symbolic Index - O(1) Path Lookup

  Maintains a mapping of absolute filesystem paths to Node PIDs.
  Provides instant access to nodes when the exact path is known.
  
  Primary use case: Automated agents and scripts that know exact file paths.
  """

  @table_name :symbolic_index

  # API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a node's path with its PID.
  Called during file/directory ingestion.
  """
  def register_path(path, node_pid) when is_binary(path) and is_pid(node_pid) do
    :ets.insert(@table_name, {path, node_pid})
    :ok
  end

  @doc """
  Looks up a node by its absolute path.
  Returns {:ok, pid} or {:error, :not_found}.
  
  Complexity: O(1)
  """
  def get_node_by_path(path) when is_binary(path) do
    case :ets.lookup(@table_name, path) do
      [{^path, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          # Clean up dead PID
          :ets.delete(@table_name, path)
          {:error, :not_found}
        end
      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Unregisters a path (e.g., when node is terminated).
  """
  def unregister_path(path) when is_binary(path) do
    :ets.delete(@table_name, path)
    :ok
  end

  @doc """
  Returns all registered paths (for debugging/admin).
  """
  def list_all_paths do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {path, pid} -> {path, pid, Process.alive?(pid)} end)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table with public read access
    :ets.new(@table_name, [
      :named_table,
      :set,           # Each path maps to one PID
      :public,        # Allow other processes to read
      read_concurrency: true
    ])

    Logger.info("SymbolicIndex: Path registry initialized")
    {:ok, %{}}
  end
end
