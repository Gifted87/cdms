defmodule CREMS.Symbiosis.DefinitionLinker do
  use GenServer
  require Logger

  alias CMS.SymbolicIndex

  @moduledoc """
  The Bridge between Anatomy (CDMS) and Physiology (CREMS).
  Resolves "What file defines this process?"
  """

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers a linkage check for a specific CREMS Node.
  Usually called during ModellingAgent genesis.
  """
  def link_node(node_id) do
    GenServer.cast(__MODULE__, {:link_node, node_id})
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    # Periodic sweep every 30 seconds
    Process.send_after(self(), :periodic_sweep, 30_000)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:link_node, node_id}, state) do
    perform_linkage(node_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_sweep, state) do
    # Scan all CREMS nodes in Registry
    # This is slightly expensive, but exhaustive O(N_runtime).
    Registry.select(CMS.NodeRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.each(fn {crems_id, _pid, _} -> 
       # We only link if it's a pid-node-*
       if String.starts_with?(crems_id, "pid-node-") do
          perform_linkage(crems_id)
       end
    end)

    Process.send_after(self(), :periodic_sweep, 30_000)
    {:noreply, state}
  end

  # --- Internal ---

  defp perform_linkage(crems_id) do
    case Registry.lookup(CMS.NodeRegistry, crems_id) do
      [{pid, _}] ->
        # Retrieve CREMS Snapshot
        case GenServer.call(pid, :get_state_snapshot) do
          {:ok, crems_node} ->
            path = crems_node.body.executable_path
            resolve_linkage(crems_id, path)
          _ -> :ok
        end
      _ -> :ok
    end
  end

  defp resolve_linkage(_crems_id, nil), do: :ok
  defp resolve_linkage(crems_id, path) do
    case SymbolicIndex.get_node_by_path(path) do
      {:ok, cdms_pid} ->
        # Retrieve CDMS ID
        case GenServer.call(cdms_pid, :get_state_snapshot) do
          {:ok, cdms_node} ->
            establish_bridge(crems_id, cdms_node.id, cdms_pid)
          _ -> :ok
        end
      {:error, :not_found} ->
        :ok
    end
  end

  defp establish_bridge(crems_id, cdms_id, cdms_pid) do
    # 1. Update CREMS Node: {:defined_by, cdms_id}
    # Using existing upsert_edge in CREMS.NodeActor
    case Registry.lookup(CMS.NodeRegistry, crems_id) do
      [{pid, _}] -> 
        GenServer.cast(pid, {:upsert_edge, :defined_by, cdms_id, %{}})
      _ -> :ok
    end

    # 2. Update CDMS Node: {:defines, crems_id}
    # CDMS NodeActor uses handle_cast({:add_edge, edge}, state)
    edge = CMS.Edge.new(crems_id, :defines, 1.0)
    GenServer.cast(cdms_pid, {:add_edge, edge})
    
    Logger.info("[SYMBIOIS] Bridge established: #{crems_id} <---> #{cdms_id} (#{crems_id} is defined by #{cdms_id})")
  end
end
