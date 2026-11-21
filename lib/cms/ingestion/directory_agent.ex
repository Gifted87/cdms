defmodule CMS.Ingestion.DirectoryAgent do
  use GenServer
  require Logger
  alias CMS.Ingestion.{ExclusionCortex, FileIngestionTask}

  # Matches ML Bridge (Python) model
  @embedding_model "all-MiniLM-L6-v2"

  @moduledoc """
  The Wavefront Algorithm Agent.
  Traverses directories recursively, spawning FileIngestionTasks and new DirectoryAgents.
  """

  def start_link({path, parent_id, spatial_coords, width_descriptor, opts}) do
    GenServer.start_link(__MODULE__, {path, parent_id, spatial_coords, width_descriptor, opts})
  end

  @impl true
  def init({path, parent_id, spatial_coords, width_descriptor, opts}) do
    # 0. Trap Exit to ensure we can handle cleanup if needed (Phase 2 resilience)
    Process.flag(:trap_exit, true)
    
    state = %{
      path: path,
      parent_id: parent_id,
      spatial_coords: spatial_coords,
      width_descriptor: width_descriptor,
      opts: Keyword.put_new(opts, :circle_root, path), # Default circle root to starting path if not present
      my_uuid: nil,
      children_uuids: []
    }
    
    # Start the Wavefront
    send(self(), :genesis_sequence)
    {:ok, state}
  end

  @impl true
  def handle_info(:genesis_sequence, state) do
    if ExclusionCortex.should_traverse?(state.path) do
      # 1. Instantiate SELF as a Node (Representation of the Directory)
      case ensure_directory_node(state.path, state.parent_id, state.spatial_coords, state.width_descriptor, state.opts) do
        nil ->
          Logger.error("DirectoryAgent: Failed to ensure directory node for #{state.path}. Wavefront halted.")
          {:noreply, state}
  
        {my_uuid, my_status} ->
          # Track if any child or self was touched
          state = Map.put(state, :drift_detected, if(my_status == :touched, do: true, else: false))
          # 2. SCAN
          case File.ls(state.path) do
          {:ok, items} ->
            # 3. COMPUTE MEMBERSHIP HASH (Selective Sync)
            current_membership_hash = compute_membership_hash(state.path, items)
            
            # Retrieve old hash from Mnesia
            stored_membership_hash = 
              case :mnesia.dirty_read(:nodes_table, my_uuid) do
                [{:nodes_table, _, _, _, _, _, _, _, provenance, _}] -> Map.get(provenance || %{}, "membership_hash")
                _ -> nil
              end

            # 4. FILTER
            filtered_items = 
              items 
              |> Enum.map(fn item -> Path.join(state.path, item) end)
              |> Enum.filter(&ExclusionCortex.should_traverse?/1)

            if current_membership_hash == stored_membership_hash and Application.get_env(:acn_cms, :incremental_genesis, true) do
              Logger.info("DirectoryAgent: No membership drift for #{state.path}. Hydrating existing subtree.")
              
              # Fast-path: Just ensure all known child actors are started
              child_uuids = 
                case :mnesia.dirty_read(:nodes_table, my_uuid) do
                  [{:nodes_table, _, _, _, _, _, tail, _, _, _}] -> 
                    Enum.filter(tail.hierarchical, &(&1.type == :parent_of)) |> Enum.map(& &1.target_node_id)
                  _ -> []
                end

              # Use async_stream to start child actors without recursive scanning
              child_uuids |> Enum.each(&CMS.NodeSupervisor.start_node_from_store/1)
              
              # Signal completion with status
              if notify_pid = state.opts[:notify_pid] do
                 send(notify_pid, {:wavefront_complete, self(), state.drift_detected})
              end

              {:noreply, %{state | my_uuid: my_uuid, children_uuids: child_uuids}}
            else
              # 5. SPAWN (Mitosis) -> Parallel
              {_x, _y, z} = state.spatial_coords
              
              items_with_meta = Enum.with_index(filtered_items) |> Enum.map(fn {item_path, idx} ->
                r = :math.sqrt(idx + 1)
                theta = 2.4 * idx
                child_coords = {r * :math.cos(theta), r * :math.sin(theta), z + 1}
                child_char = <<65 + rem(idx, 26)>>
                parent_base = String.replace(state.width_descriptor, ~r/\d+$/, "")
                child_width = "#{parent_base}#{child_char}0"
                {item_path, child_coords, child_width}
              end)

              {children_uuids, children_drift} = 
                items_with_meta
                |> Task.async_stream(fn {item_path, coords, width} ->
                  if File.dir?(item_path) do
                     child_opts = Keyword.delete(state.opts, :notify_pid)
                     {:ok, pid} = CMS.NodeSupervisor.start_directory_agent(item_path, my_uuid, coords, width, child_opts)
                     try do
                       GenServer.call(pid, :await_genesis, :infinity)
                     catch
                       _, _ -> {:error, :timeout}
                     end
                  else
                     FileIngestionTask.ingest(item_path, my_uuid, coords, width, state.opts)
                  end
                end, max_concurrency: 5, timeout: :infinity)
                |> Enum.reduce({[], state.drift_detected}, fn 
                  {:ok, {:ok, :touched, id}}, {uuids, _} -> {[id | uuids], true}
                  {:ok, {:ok, :skipped, id}}, {uuids, drift} -> {[id | uuids], drift}
                  {:ok, {:ok, status, id}}, {uuids, _} when status in [:touched, :skipped] -> {[id | uuids], status == :touched}
                  {:ok, id}, {uuids, drift} when is_binary(id) -> {[id | uuids], drift} # Fallback for legacy calls
                  _, acc -> acc
                end)

              update_edges(my_uuid, children_uuids)
              
              # Store newest membership hash
              update_membership_hash(my_uuid, current_membership_hash)

              CMS.Services.LiveWire.watch(state.path)
              Logger.info("DirectoryAgent: Wavefront complete for #{state.path}. Monitoring.")
              
              if notify_pid = state.opts[:notify_pid] do
                 send(notify_pid, {:wavefront_complete, self(), children_drift})
              end

              {:noreply, %{state | my_uuid: my_uuid, children_uuids: children_uuids, drift_detected: children_drift}}
            end

          {:error, reason} ->
            Logger.error("DirectoryAgent: Failed to scan #{state.path}: #{inspect(reason)}")
            {:stop, reason, state}
        end
      end
    else
      Logger.debug("DirectoryAgent: Skipping genesis for blocked path #{state.path}")
      {:stop, :normal, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp compute_membership_hash(path, items) do
    items
    |> Enum.sort()
    |> Enum.map(fn item ->
      full_path = Path.join(path, item)
      case File.stat(full_path) do
        {:ok, %File.Stat{mtime: mtime, size: size}} -> "#{item}:#{inspect(mtime)}:#{size}"
        _ -> item
      end
    end)
    |> Enum.join("|")
    |> then(& :crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp update_membership_hash(uuid, hash) do
    case CMS.NodeSupervisor.get_node(uuid) do
      {:ok, node} ->
        # Write through the actor so it is the source of truth.
        # The actor will then persist to Mnesia correctly.
        new_provenance = Map.put(node.provenance || %{}, "membership_hash", hash)
        updated_node = %{node | provenance: new_provenance}
        CMS.NodeSupervisor.update_node(updated_node)
      _ ->
        # Actor not up yet – write directly to Mnesia as a safe fallback
        case :mnesia.dirty_read(:nodes_table, uuid) do
          [record] ->
            provenance = elem(record, 8) || %{}
            new_provenance = Map.put(provenance, "membership_hash", hash)
            new_record = put_elem(record, 8, new_provenance)
            :mnesia.dirty_write(new_record)
          _ -> :ok
        end
    end
  end


  @impl true
  def handle_call(:await_genesis, _from, state) do
    # This message is processed after :genesis_sequence, so we know we are done.
    {:reply, {:ok, if(Map.get(state, :drift_detected, false), do: :touched, else: :skipped), state.my_uuid}, state}
  end
  

  defp ensure_directory_node(path, parent_id, spatial_coords, width_descriptor, opts) do
    uuid = UUID.uuid5(:oid, path)

    # Idempotency Check: See if node already exists in Mnesia
    existing = :mnesia.dirty_read(:nodes_table, uuid)

    case existing do
      [{:nodes_table, ^uuid, _hash, _parent, _head, %{data_head: %{summary: "Processing failed" <> _}}, _tail, _stack, _provenance, _antenna}] ->
        # Existing node found but it was a failure. Clean up and re-ingest.
        Logger.info("DirectoryAgent: Re-ingesting previously failed node: #{path}")
        :mnesia.dirty_delete(:nodes_table, uuid)
        cog_mode = Keyword.get(opts, :cognitive_mode, :generative)
        do_ensure_directory_node(uuid, path, parent_id, spatial_coords, width_descriptor, cog_mode)

      [{:nodes_table, ^uuid, _hash, _parent, _head, _body, _tail, _stack, _provenance, _antenna}] ->
        # Node exists and looks valid. Ensure actor is running.
        case CMS.NodeSupervisor.start_node_from_store(uuid) do
          {:ok, pid} -> CMS.SymbolicIndex.register_path(path, pid)
          _ -> :ok
        end
        {uuid, :skipped}

      [] ->
        # Propagate cognitive mode to directory summary generation
        cog_mode = Keyword.get(opts, :cognitive_mode, :generative)
        do_ensure_directory_node(uuid, path, parent_id, spatial_coords, width_descriptor, cog_mode)
    end
  end

  defp do_ensure_directory_node(uuid, path, parent_id, spatial_coords, width_descriptor, cog_mode) do
    # Generate meaningful directory summary
    case generate_directory_summary(path, cog_mode) do
      {:ok, {summary, concepts}} ->
        # Generate proper embedding from the summary
        embedding = case CMS.Tool.Embedder.generate("#{Path.basename(path)}: #{summary}", @embedding_model) do
          {:ok, tensor} -> tensor
          {:error, _reason} -> Nx.tensor(List.duplicate(0.1, 384))
        end
        
        head = CMS.NodeHead.new(uuid, embedding, @embedding_model, 0.35, spatial_coords, width_descriptor)
        
        data_head = CMS.DataHead.new(summary, concepts)
        
        # Extract full anatomy for directories
        essence = CMS.Ingestion.AnatomyEngine.extract_essence(path)
        metabolism = :static_bone  # Directories are always static bone
        
        # Calculate Salience for the directory
        salience = CMS.SalienceEngine.calculate(summary, %{"priority" => "high", "type" => "directory"}, mode: cog_mode)
        
        # Create DataTail with complete anatomical ledger
        data_ledger = CMS.DataTail.new(
          path, "dir_hash", "inode/directory", salience,
          essence.permissions, essence.ownership, essence.immutable_flags,
          essence.genetic_provenance, metabolism
        )
        
        body = CMS.NodeBody.new(data_head, nil, data_ledger, :shallow)
        antenna = CMS.NodeAntenna.new(path, salience)
        
        node = CMS.Node.new(head, body, antenna, %{"type" => "directory"})
        
        # Add Parent Link
        node = if parent_id do
           edge = CMS.Edge.new(parent_id, :child_of, 1.0)
           %{node | tail: CMS.NodeTail.add_edge(node.tail, edge)}
        else
           node
        end
        
        # Register in VectorRouter
        CMS.VectorRouter.register_name(Path.basename(path), uuid)
        CMS.VectorRouter.add_embedding(uuid, embedding, @embedding_model)

        # Persist - 9 fields: uuid, path_hash, parent_uuid, head_data, body_data, tail_data, chrono_stack, provenance, antenna_data
        # Preserve any existing provenance (e.g. membership_hash written by a previous run)
        # so the incremental fast-path is not defeated on restart.
        existing_provenance =
          case :mnesia.dirty_read(:nodes_table, uuid) do
            [{:nodes_table, _, _, _, _, _, _, _, prov, _}] when is_map(prov) -> prov
            _ -> %{}
          end
        :mnesia.dirty_write({:nodes_table, uuid, UUID.uuid5(:oid, path), parent_id, node.head, node.body, node.tail, CMS.ChronoStack.new(), existing_provenance, node.antenna})
    
        # Append to epoch log for rehydration capability
        CMS.LogAppender.append_node_event(uuid, :node_created, node)
        
        case CMS.NodeSupervisor.spawn_node(node) do
          {:ok, pid} ->
            # Register path for symbolic lookup
            CMS.SymbolicIndex.register_path(path, pid)
            :ok
          _ -> :ok
        end
        
        {uuid, :touched}

      {:error, _reason} ->
        nil
    end
  end

  # Generate a meaningful summary for a directory based on its contents
  defp generate_directory_summary(path, cog_mode) do
    dir_name = Path.basename(path)
    
    # List contents to provide context
    contents = case File.ls(path) do
      {:ok, items} -> 
        filtered = items 
          |> Enum.filter(&ExclusionCortex.should_traverse?(Path.join(path, &1)))
          |> Enum.take(20)  # Limit for context window
        
        {files, dirs} = Enum.split_with(filtered, fn item -> 
          !File.dir?(Path.join(path, item))
        end)
        
        file_summary = if length(files) > 0 do
          ext_groups = files 
            |> Enum.group_by(&Path.extname/1) 
            |> Enum.map(fn {ext, list} -> "#{length(list)} #{ext || "no ext"}" end)
            |> Enum.join(", ")
          "Files: #{ext_groups}"
        else
          "No files"
        end
        
        dir_summary = if length(dirs) > 0 do
          "Subdirectories: #{Enum.join(dirs, ", ")}"
        else
          "No subdirectories"
        end
        
        "#{file_summary}. #{dir_summary}"
      {:error, _} -> "Unable to scan contents"
    end
    
    # Build context for LLM with explicit directory context
    prompt = """
    SYSTEM: You are a software architect analyzing a project's file structure.
    TASK: Summarize the purpose of this DIRECTORY based on its name and contents.
    DIRECTORY: #{dir_name}
    PATH: #{path}
    CONTENTS: #{contents}
    
    INSTRUCTION: Explain what this directory likely contains or its role in the system. 
    OUTPUT JSON: { "summary": "A directory containing...", "concepts": ["Directory", "..."] }
    """
    
    if cog_mode == :deterministic do
      # Use Deterministic Aggregator for directory as well
      {:ok, {summary, _concepts}} = CMS.Ingestion.DeterministicAggregator.aggregate(path, contents, "inode/directory")
      concepts = [dir_name, "Directory"]
      {:ok, {summary, concepts}}
    else
      summary_result = CMS.Infrastructure.GeminiBridge.summarize(prompt, "gemini-2.5-flash-lite", path)

      case summary_result do
        {:ok, %{"summary" => s, "concepts" => c}} when is_binary(s) and is_list(c) ->
          {:ok, {s, c}}
        {:ok, %{"summary" => s}} when is_binary(s) ->
          {:ok, {s, [dir_name, "Directory"]}}
        {:error, reason} ->
          Logger.error("DirectoryAgent: LLM summarization failed for #{path}: #{inspect(reason)}")
          {:error, reason}
        other ->
          Logger.error("DirectoryAgent: Unexpected LLM response for #{path}: #{inspect(other)}")
          {:error, :unexpected_response}
      end
    end
  end

  defp update_edges(my_uuid, children_uuids) do
    case :mnesia.dirty_read(:nodes_table, my_uuid) do
      [{_table, _uuid, _hash, _pid, head, body, tail, stack, provenance, antenna}] ->
        # Strip all existing :parent_of edges before rebuilding to prevent
        # duplicate accumulation across multiple Genesis runs on the same directory.
        clean_hierarchical =
          Enum.reject(tail.hierarchical, fn e -> e.type == :parent_of end)
        clean_tail = %{tail | hierarchical: clean_hierarchical}

        new_tail = Enum.reduce(children_uuids, clean_tail, fn child_id, acc ->
          CMS.NodeTail.add_edge(acc, CMS.Edge.new(child_id, :parent_of, 1.0))
        end)
        
        # Increment parent width
        current_width_str = head.width_descriptor
        [prefix, count_str] = Regex.run(~r/^(.*?)([0-9]+)$/, current_width_str, capture: :all_but_first)
        new_count = String.to_integer(count_str) + 1
        new_width_str = "#{prefix}#{new_count}"

        new_head = %{head | width_descriptor: new_width_str}
        new_stack = CMS.ChronoStack.push(stack, current_width_str, new_width_str, "structural_hash", :structural_mutation)
        
        # Construct updated Node struct to sync with Actor
        updated_node = %CMS.Node{
           id: my_uuid,
           head: new_head,
           body: %{body | data_ledger: %{body.data_ledger | chrono_stack: new_stack}},
           tail: new_tail,
           antenna: antenna,
           provenance: provenance
        }
        
        # OPTIMIZATION: Use local Mnesia state during Genesis to prevent timeouts.
        # The Actor is likely busy initializing. We trust the local update.
        CMS.NodeSupervisor.update_node(updated_node)
        
      [] ->
        Logger.error("DirectoryAgent: Could not find my own node #{my_uuid} to update edges.")
    end
  end
end
