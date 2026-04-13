defmodule CMS.VectorRouter do
  use GenServer
  require Logger

  @moduledoc """
  Manages the Hierarchical Navigable Small Worlds (HNSW) index for vector embeddings.

  CRITICAL REMEDIATION:
  1. FIX: Updated 'add' and 'query' to pass Nx.Tensor directly to HNSWLib as required by the binding.
  2. FIX: Ensures 1D vectors are correctly converted to 2D batches (Nx.new_axis).
  3. FIX: Uses safer ID generation to prevent NIF integer overflow issues.
  4. QUERY FIX: Added logic to respect the `threshold` option.
  """

  # Configuration

  @dim 384
  @max_elements 100_000
  @persist_interval :timer.minutes(5)
  @persist_threshold 100
  @id_map_table :vector_id_mapping

  # Supported Models
  @supported_models ["nomic-embed-text", "all-MiniLM-L6-v2", "custom-bert-v1"]
  @nominal_table :nominal_index

  defstruct [
    :indices,           # Map: %{model_version => index_ref}
    :insertion_count,   # Map: %{model_version => count}
    :dirty_models       # MapSet: Tracks models with unpersisted changes
  ]

  # --- Client API ---

  def find_by_name(name) do
    case :mnesia.dirty_read(@nominal_table, name) do
      [{_, ^name, uuid}] -> {:ok, uuid}
      _ -> {:error, :not_found}
    end
  end

  def register_name(name, uuid) do
    :mnesia.dirty_write({@nominal_table, name, uuid})
  end

  def resolve_path(path) do
    find_by_name(path)
  end

  def get_name_for_uuid(uuid) do
    case :mnesia.dirty_read(:nodes_table, uuid) do
      [{_table, ^uuid, _hash, _parent, _head, body, _tail, _stack, _provenance, _antenna}] ->
        Path.basename(get_in(body, [:data_head, :summary]) || get_in(body, [:data_ledger, :physical_symlink]) || "unknown")
      _ ->
        case :mnesia.dirty_read(:nodes_table, uuid) do
           [{_table, ^uuid, _hash, _parent, _head, body, _tail, _stack, _provenance}] ->
             Path.basename(get_in(body, [:data_head, :summary]) || get_in(body, [:data_ledger, :physical_symlink]) || "unknown")
           _ -> nil
        end
    end
  end


  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def add_embedding(node_id, embedding, model_version) do
    GenServer.call(__MODULE__, {:add, node_id, embedding, model_version}, 30_000)
  end

  def query(query_vector, model_version, opts \\ []) do
    GenServer.call(__MODULE__, {:query, query_vector, model_version, opts}, 10_000)
  end

  def persist do
    GenServer.call(__MODULE__, :persist)
  end

  @doc "Destroys all indices on disk. Hazardous."
  def clean_slate do
    File.rm_rf(base_index_dir())
  end
  
  @doc "Optimized bulk insertion for Rehydration."
  def bulk_add(items, model_version) do
    # items is a list of {node_id, embedding_tensor}
    GenServer.call(__MODULE__, {:bulk_add, items, model_version}, 60_000)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    # 1. Ensure Index directory exists
    File.mkdir_p!(base_index_dir())

    # 2. Initialize Mnesia (Safe to call multiple times if handled)
    init_mnesia()

    # 3. Load or Create indices
    {initial_indices, initial_counts} =
      Enum.reduce(@supported_models, {[], []}, fn model, {indices_acc, counts_acc} ->
        path = index_file_path(model)
        
        case attempt_load_index(model, path) do
          {:ok, index, count} ->
            Logger.info("CMS.VectorRouter: Loaded existing index for #{model} (#{count} items).")
            {[{model, index} | indices_acc], [{model, count} | counts_acc]}
            
          {:error, :not_found} ->
            Logger.info("CMS.VectorRouter: No index found for #{model}. Creating fresh.")
            {:ok, index} = HNSWLib.Index.new(:cosine, @dim, @max_elements)
            {[{model, index} | indices_acc], [{model, 0} | counts_acc]}

          {:error, reason} ->
            Logger.error("CMS.VectorRouter: Failed to load index for #{model}: #{inspect(reason)}. Creating fresh.")
            File.rm(path)
            {:ok, index} = HNSWLib.Index.new(:cosine, @dim, @max_elements)
            {[{model, index} | indices_acc], [{model, 0} | counts_acc]}
        end
      end)

    Process.send_after(self(), :periodic_persist, @persist_interval)

    {:ok, %__MODULE__{
      indices: Map.new(initial_indices),
      insertion_count: Map.new(initial_counts),
      dirty_models: MapSet.new()
    }}
  end

  @impl true
  def handle_call({:add, node_id, embedding, model_version}, _from, state) do
    case Map.fetch(state.indices, model_version) do
      {:ok, index} when not is_nil(index) ->
        try do
          # CRITICAL FIX 1: Ensure embedding is a 2D Nx.Tensor (a batch of 1 vector)
          vector_tensor =
            case Nx.rank(embedding) do
              1 -> Nx.new_axis(embedding, 0) # Convert 1D [384] to 2D [1][384]
              _ -> embedding
            end

          # CRITICAL FIX 2: Dimension Check - use Nx.shape for a 2D tensor
          tensor_dim = elem(Nx.shape(vector_tensor), 1)

          if tensor_dim != @dim do
            Logger.error("Dimension mismatch: Expected #{@dim}, got #{tensor_dim}.")
            {:reply, {:error, :dimension_mismatch}, state}
          else
            # 2. Generate ID
            # FIX 3: Use sequential IDs to avoid exceeding max_elements (if it limits label range) and ensuring valid range.
            # Since we only add, insertion_count is roughly the next ID.
            current_id = Map.get(state.insertion_count, model_version, 0)
            item_id = current_id + 1

            # 3. Add to HNSW (Pass the Nx.Tensor directly)
            case HNSWLib.Index.add_items(index, vector_tensor, ids: [item_id]) do
              :ok ->
                :mnesia.dirty_write({@id_map_table, item_id, node_id})
                new_count = current_id + 1
                new_dirty = MapSet.put(state.dirty_models, model_version)

                if new_count >= @persist_threshold, do: send(self(), :periodic_persist)

                {:reply, :ok, %{state | insertion_count: Map.put(state.insertion_count, model_version, new_count), dirty_models: new_dirty}}

              {:error, reason} ->
                Logger.error("HNSWLib.add_items failed: #{inspect(reason)}")
                {:reply, {:error, :add_failed}, state}
            end
          end
        rescue
          e ->
            Logger.error("VectorRouter Crash on Add: #{inspect(e)}")
            {:reply, {:error, :add_crashed}, state}
        catch
          :exit, reason ->
             Logger.error("VectorRouter NIF Crash (Exit): #{inspect(reason)}")
             {:reply, {:error, :nif_crash}, state}
        end

      _ ->
        {:reply, {:error, :unsupported_model}, state}
    end
  end

  @impl true
  def handle_call({:bulk_add, items, model_version}, _from, state) do
    case Map.fetch(state.indices, model_version) do
      {:ok, index} when not is_nil(index) ->
        # 1. Prepare batch
        # items is [{node_id, tensor}]
        # Need to separate into a Tensor Batch and a List of IDs
        
        {ids, tensors} = Enum.reduce(items, {[], []}, fn {node_id, tensor}, {id_acc, t_acc} ->
             # Generate ID
             item_id = :erlang.phash2(node_id, 2_147_483_647)
             
             # Shape Check
             t = case Nx.rank(tensor) do
               1 -> Nx.new_axis(tensor, 0)
               _ -> tensor
             end
             
             {[item_id | id_acc], [t | t_acc]}
        end)
        
        # Nx.concatenate requires same-shaped tensors. 
        # Since we new_axis'd them to [1, 384], concat on axis 0 gives [N, 384].
        if Enum.empty?(tensors) do
           {:reply, :ok, state}
        else
           # Reverse to maintain order (reduce prepends)
           final_tensors = Enum.reverse(tensors) |> Nx.concatenate(axis: 0)
           final_ids = Enum.reverse(ids)
           
           # Direct HNSW Bulk Add
           case HNSWLib.Index.add_items(index, final_tensors, ids: final_ids) do
             :ok ->
               # Bulk Write Mnesia Mappings
               mappings = Enum.zip(final_ids, Enum.map(items, fn {nid, _} -> nid end))
               
               :mnesia.transaction(fn -> 
                  Enum.each(mappings, fn {iid, nid} ->
                    :mnesia.write({@id_map_table, iid, nid})
                  end)
               end)
               
               new_count = Map.get(state.insertion_count, model_version, 0) + length(items)
               new_dirty = MapSet.put(state.dirty_models, model_version)
               
               {:reply, :ok, %{state | insertion_count: Map.put(state.insertion_count, model_version, new_count), dirty_models: new_dirty}}
               
             {:error, reason} ->
                Logger.error("HNSW Bulk Add Failed: #{inspect(reason)}")
                {:reply, {:error, reason}, state}
           end
        end
        
      _ ->
        {:reply, {:error, :unsupported_model}, state}
    end
  end

  @impl true
  def handle_call({:query, query_vector, model_version, opts}, _from, state) do
    case Map.fetch(state.indices, model_version) do
      {:ok, index} when not is_nil(index) ->
        try do
          k = Keyword.get(opts, :k, 10)
          current_count = Map.get(state.insertion_count, model_version, 0)
          
          # CRITICAL FIX: Cap k by current_count to prevent HNSWLib error
          k = min(k, current_count)

          threshold = Keyword.get(opts, :threshold, 0.0)

          # CRITICAL FIX 4: Pass the Nx.Tensor directly
          query_tensor =
            case Nx.rank(query_vector) do
              1 -> Nx.new_axis(query_vector, 0)
              _ -> query_vector
            end

          # Optimization: Check if index is empty
          if current_count == 0 do
             {:reply, {:ok, []}, state}
          else
            # HNSWLib.Index.knn_query expects a 2D Nx.Tensor and returns 1D Nx.Tensors
            case HNSWLib.Index.knn_query(index, query_tensor, k: k) do
              {:ok, labels_tensor, distances_tensor} ->
                # Convert Nx.Tensors to lists
                flat_labels = Nx.to_flat_list(labels_tensor)
                flat_dists = Nx.to_flat_list(distances_tensor)

                results =
                  Enum.zip(flat_labels, flat_dists)
                  # HNSWLib returns distance. For cosine, similarity = 1.0 - distance.
                  |> Enum.map(fn {label, dist} -> {label, 1.0 - dist} end)
                  |> Enum.filter(fn {_label, similarity} -> similarity >= threshold end)
                  |> Enum.map(fn {int_id, similarity} ->
                    case :mnesia.dirty_read(@id_map_table, int_id) do
                      [{_, ^int_id, uuid}] -> {uuid, similarity}
                      _ -> nil
                    end
                  end)
                  |> Enum.reject(&is_nil/1)

                {:reply, {:ok, results}, state}

              {:error, msg} ->
                if is_binary(msg) and String.contains?(msg, "too small"), do: {:reply, {:ok, []}, state}, else: {:reply, {:error, msg}, state}

              nil ->
                {:reply, {:ok, []}, state}

              other ->
                Logger.error("VectorRouter: Unknown NIF return: #{inspect(other)}")
                {:reply, {:ok, []}, state}
            end
          end
        rescue
          e ->
            Logger.error("VectorRouter Query Crash: #{inspect(e)}")
            {:reply, {:ok, []}, state}
        end

      _ ->
        {:reply, {:ok, []}, state}
    end
  end

  @impl true
  def handle_call(:persist, _from, state) do
    Enum.each(state.indices, fn {model, index} -> save_to_disk(model, index) end)
    {:reply, :ok, %{state | dirty_models: MapSet.new(), insertion_count: Map.new()}}
  end

  @impl true
  def handle_info(:periodic_persist, state) do
    Enum.each(MapSet.to_list(state.dirty_models), fn model ->
      if index = Map.get(state.indices, model) do
        save_to_disk(model, index)
      end
    end)
    Process.send_after(self(), :periodic_persist, @persist_interval)
    {:noreply, %{state | dirty_models: MapSet.new(), insertion_count: Map.new()}}
  end

  # --- Internals ---

  defp attempt_load_index(_model, path) do
    if File.exists?(path) do
      case HNSWLib.Index.load_index(:cosine, @dim, path, max_elements: @max_elements) do
        {:ok, index} ->
          count = :mnesia.async_dirty(fn -> 
            :mnesia.table_info(@id_map_table, :size)
          end)
          {:ok, index, count}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  defp init_mnesia do
    nodes = [Node.self()]
    :mnesia.create_table(@id_map_table, [
      attributes: [:int_id, :uuid],
      disc_copies: nodes,
      type: :set
    ])
    :mnesia.create_table(@nominal_table, [
      attributes: [:name, :uuid],
      disc_copies: nodes,
      type: :set
    ])
    :mnesia.wait_for_tables([@id_map_table, @nominal_table], 5000)
  end


  defp save_to_disk(model_version, index) do
    path = index_file_path(model_version)
    if index do
      HNSWLib.Index.save_index(index, path)
    end
  end

  defp index_file_path(model_version) do
    dir = base_index_dir()
    File.mkdir_p!(dir)
    Path.join(dir, "#{String.replace(model_version, "-", "_")}.hnsw.bin")
  end

  defp base_index_dir do
    data_root = Application.get_env(:acn_cms, :data_root) || "priv/data"
    Path.join(data_root, "hnsw_indices")
  end

  # Removed: to_flat_list_sanitized/1 as it is no longer needed.
end
