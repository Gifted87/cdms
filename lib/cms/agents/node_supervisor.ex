defmodule CMS.NodeSupervisor do
  use DynamicSupervisor
  require Logger

  @moduledoc """
  Manages the lifecycle of all CMS.NodeActor processes.

  Responsibilities:
  1. Starts NodeActors dynamically upon Ingestion or Cold Boot.
  2. Restarts transient failures.
  3. Provides lookup utilities (PID retrieval).
  """

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

    @doc """
  Spawns a new NodeActor for the given Node struct.
  """
  @spec start_child(CMS.Node.t()) :: {:ok, pid()} | {:error, any()}
  def start_child(%CMS.Node{} = node) do
    child_spec = %{
      id: node.id,
      start: {CMS.NodeActor, :start_link, [node]},
      restart: :transient
    }
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def spawn_node(node), do: start_child(node)

  @doc """
  Hydrates a single node from Mnesia and starts its process.
  Used for idempotency checks in Genesis.
  """
  def start_node_from_store(uuid) do
    if pid = get_node_pid(uuid) do
      {:ok, pid}
    else
      case :mnesia.dirty_read(:nodes_table, uuid) do
        [{:nodes_table, uuid, _hash, _p_uuid, head, body, tail, stack, provenance, antenna}] ->
          node = %CMS.Node{
            id: uuid,
            head: head,
            body: %{body | data_ledger: %{body.data_ledger | chrono_stack: stack}},
            tail: tail,
            antenna: antenna,
            provenance: provenance
          }
          case start_child(node) do
            {:ok, pid} = result ->
              # Register with LiveWire and SymbolicIndex
              if body.data_ledger && body.data_ledger.physical_symlink do
                CMS.Services.LiveWire.watch(body.data_ledger.physical_symlink)
                CMS.SymbolicIndex.register_path(body.data_ledger.physical_symlink, pid)
              end
              result
            error -> error
          end

        [{:nodes_table, uuid, _hash, _p_uuid, head, body, tail, stack, provenance}] ->
          # Backward compatibility for old records without antenna field
          node = %CMS.Node{
            id: uuid,
            head: head,
            body: %{body | data_ledger: %{body.data_ledger | chrono_stack: stack}},
            tail: tail,
            antenna: CMS.NodeAntenna.new(body.data_ledger.physical_symlink),
            provenance: provenance
          }
          case start_child(node) do
            {:ok, pid} = result ->
              # Register with LiveWire and SymbolicIndex
              if body.data_ledger && body.data_ledger.physical_symlink do
                CMS.Services.LiveWire.watch(body.data_ledger.physical_symlink)
                CMS.SymbolicIndex.register_path(body.data_ledger.physical_symlink, pid)
              end
              result
            error -> error
          end
          
        _ -> {:error, :not_found}
      end
    end
  end

  @doc """
  Retrieves a full Node snapshot by ID.
  """
  def get_node(node_id) do
    case get_node_pid(node_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_state_snapshot)
    end
  end

  @doc """
  Updates a running node's state.
  """
  def update_node(%CMS.Node{id: id} = node) do
    case get_node_pid(id) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:update_node, node})
    end
  end

  def start_directory_agent(path, parent_id, spatial_coords \\ {0.0, 0.0, 0}, width_descriptor \\ "m0", opts \\ []) do
    # Corrected module name
    CMS.Ingestion.DirectoryAgent.start_link({path, parent_id, spatial_coords, width_descriptor, opts})
  end

  @doc """
  Terminates a node and recursively terminates its hierarchical children.
  Scrubs all from Mnesia.
  """
  def terminate_node(node_id) do
    case :mnesia.dirty_read(:nodes_table, node_id) do
      [record] when is_tuple(record) and tuple_size(record) >= 7 ->
        tail = elem(record, 6)
        # Hierarchical recursion: terminate all children
        Enum.each(tail.hierarchical, fn edge ->
          if edge.type == :parent_of do
             terminate_node(edge.target_id)
          end
        end)

        # Scour self
        case get_node_pid(node_id) do
          nil -> :ok
          pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
        end
        
        :mnesia.dirty_delete(:nodes_table, node_id)
        Logger.info("CMS.NodeSupervisor: Terminated node #{node_id} (and potentially children)")
        :ok

      [] -> 
        {:error, :not_found}
    end
  end

  @doc """
  Retrieves the PID of a running NodeActor by its Content-Addressable ID.
  """
  @spec get_node_pid(String.t()) :: pid() | nil
  def get_node_pid(node_id) do
    case Registry.lookup(CMS.NodeRegistry, node_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns a list of all active Node PIDs.
  """
  def get_all_active_node_pids do
    Registry.select(CMS.NodeRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
  end
end

