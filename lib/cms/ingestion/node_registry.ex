defmodule CMS.Ingestion.NodeRegistry do
  @moduledoc """
  JSON-based registry for strict indexing validation.
  Ensures no node action is taken if the file hash hasn't drifted.
  """
  use GenServer
  require Logger

  defp get_registry_path do
    mnesia_dir = Application.get_env(:mnesia, :dir) || "priv/data/mnesia_store"
    # Convert charlist to string if necessary
    mnesia_dir_str = if is_list(mnesia_dir), do: to_string(mnesia_dir), else: mnesia_dir
    # Put registry in the same root folder as mnesia_store
    root_data_dir = Path.dirname(mnesia_dir_str)
    Path.join(root_data_dir, ".cdms_node_registry.json")
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Checks if the file at `path` is unchanged in the JSON registry according to `current_hash`.
  """
  def is_unchanged?(path, current_hash) do
    GenServer.call(__MODULE__, {:is_unchanged, path, current_hash})
  end

  @doc """
  Registers or updates a node in the JSON registry and flushes to disk.
  """
  def register_node(path, current_hash, uuid) do
    GenServer.cast(__MODULE__, {:register, path, current_hash, uuid})
  end

  @impl true
  def init(_) do
    path = get_registry_path()
    registry = 
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} -> data
            _ -> %{}
          end
        _ -> %{}
      end
    {:ok, registry}
  end

  @impl true
  def handle_call({:is_unchanged, path, current_hash}, _from, registry) do
    unchanged? = 
      case Map.get(registry, path) do
        %{"hash" => ^current_hash} -> true
        _ -> false
      end
    {:reply, unchanged?, registry}
  end

  @impl true
  def handle_cast({:register, path, current_hash, uuid}, registry) do
    updated_registry = Map.put(registry, path, %{
      "hash" => current_hash,
      "uuid" => uuid,
      "path" => path
    })
    
    # Save to file
    path = get_registry_path()
    File.write!(path, Jason.encode!(updated_registry, pretty: true))
    
    {:noreply, updated_registry}
  end
end
