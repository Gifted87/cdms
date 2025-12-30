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
    # 1. Instantiate SELF as a Node (Representation of the Directory)
    case ensure_directory_node(state.path, state.parent_id, state.spatial_coords, state.width_descriptor) do
      nil ->
        Logger.error("DirectoryAgent: Failed to ensure directory node for #{state.path}. Wavefront halted.")
        {:noreply, state}

      my_uuid ->
        # 2. SCAN
    case File.ls(state.path) do
      {:ok, items} ->
        # 3. FILTER
        filtered_items = 
          items 
          |> Enum.map(fn item -> Path.join(state.path, item) end)
          |> Enum.filter(&ExclusionCortex.should_traverse?/1)

        {_files, _dirs} = classify_items(filtered_items)
        
        # 4. SPAWN (Mitosis) -> Parallel
        {_x, _y, z} = state.spatial_coords
        
        # Sibling Indexing (X/Y-Axis Breadth) & Width Descriptors
        # We use a simple circular distribution or spiral for X/Y
        items_with_meta = Enum.with_index(filtered_items) |> Enum.map(fn {item_path, idx} ->
          # Polar distribution
          r = :math.sqrt(idx + 1)
          theta = 2.4 * idx
          child_coords = {r * :math.cos(theta), r * :math.sin(theta), z + 1}
          
          # Width Descriptor: [Parent][ChildChar][Layer0]
          # We use 65 + idx to get 'A', 'B', etc.
          child_char = <<65 + rem(idx, 26)>>
          # Remove the '0' from parent width if it exists for cleaner nesting (m0 -> mc0)
          parent_base = String.replace(state.width_descriptor, ~r/\d+$/, "")
          child_width = "#{parent_base}#{child_char}0"
          
          {item_path, child_coords, child_width}
        end)

        # 4. EXECUTE (Serialized Ingestion)
        # Processing items one at a time to prevent system overload.
        
        children_results = 
          items_with_meta
          |> Task.async_stream(fn {item_path, coords, width} ->
            if File.dir?(item_path) do
               # RECURSION FIX:
               # 1. Strip :notify_pid so children don't signal the Mix task prematurely.
               child_opts = Keyword.delete(state.opts, :notify_pid)
               
               {:ok, pid} = CMS.NodeSupervisor.start_directory_agent(item_path, my_uuid, coords, width, child_opts)
               
               # 2. Synchronous Wait: Block until child finishes its scan.
               # This ensures the Root Agent finishes last.
               try do
                 GenServer.call(pid, :await_genesis, :infinity)
               catch
                 _, _ -> :ok # Handle crashes gracefully
               end

               UUID.uuid5(:oid, item_path)
            else
               # Single File Ingestion
               case FileIngestionTask.ingest(item_path, my_uuid, coords, width, state.opts) do
                 {:ok, id} -> id
                 {:ok, _, id} -> id # Handle conflict resolution case
                 _ -> nil
               end
            end
          end, max_concurrency: 1, timeout: :infinity)
          |> Enum.map(fn {:ok, result} -> result end)
          |> Enum.filter(& &1)

        all_children = children_results

        # Update my Tail with PARENT_OF edges
        update_edges(my_uuid, all_children)

        # 6. SENTINEL
        # "Transitions to inotify monitoring mode" -> LiveWire
        CMS.Services.LiveWire.watch(state.path)

        Logger.info("DirectoryAgent: Wavefront complete for #{state.path}. Monitoring.")
        
        # Signal completion if requested
        if notify_pid = state.opts[:notify_pid] do
           send(notify_pid, {:wavefront_complete, self()})
        end

        {:noreply, %{state | my_uuid: my_uuid, children_uuids: all_children}}

      {:error, reason} ->
        Logger.error("DirectoryAgent: Failed to scan #{state.path}: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:await_genesis, _from, state) do
    # This message is processed after :genesis_sequence, so we know we are done.
    {:reply, :ok, state}
  end
  
  defp classify_items(paths) do
    Enum.reduce(paths, {[], []}, fn path, {files, dirs} ->
      if File.dir?(path) do
        {files, [path | dirs]}
      else
        {[path | files], dirs}
      end
    end)
  end

  defp ensure_directory_node(path, parent_id, spatial_coords, width_descriptor) do
    uuid = UUID.uuid5(:oid, path)

    # Idempotency Check: See if node already exists in Mnesia
    existing = :mnesia.dirty_read(:nodes_table, uuid)

    case existing do
      [{:nodes_table, ^uuid, _hash, _parent, _head, %{data_head: %{summary: "Processing failed" <> _}}, _tail, _stack, _provenance, _antenna}] ->
        # Existing node found but it was a failure. Clean up and re-ingest.
        Logger.info("DirectoryAgent: Re-ingesting previously failed node: #{path}")
        :mnesia.dirty_delete(:nodes_table, uuid)
        do_ensure_directory_node(uuid, path, parent_id, spatial_coords, width_descriptor)

      [{:nodes_table, ^uuid, _hash, _parent, _head, _body, _tail, _stack, _provenance, _antenna}] ->
        # Node exists and looks valid. Ensure actor is running.
        case CMS.NodeSupervisor.start_node_from_store(uuid) do
          {:ok, pid} -> CMS.SymbolicIndex.register_path(path, pid)
          _ -> :ok
        end
        uuid

      [] ->
        do_ensure_directory_node(uuid, path, parent_id, spatial_coords, width_descriptor)
    end
  end

  defp do_ensure_directory_node(uuid, path, parent_id, spatial_coords, width_descriptor) do
    # Generate meaningful directory summary using LLM
    case generate_directory_summary(path) do
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
        salience = CMS.SalienceEngine.calculate(summary, %{"priority" => "high", "type" => "directory"})
        
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
        :mnesia.dirty_write({:nodes_table, uuid, UUID.uuid5(:oid, path), parent_id, node.head, node.body, node.tail, CMS.ChronoStack.new(), %{}, node.antenna})
    
        # Append to epoch log for rehydration capability
        CMS.LogAppender.append_node_event(uuid, :node_created, node)
        
        case CMS.NodeSupervisor.spawn_node(node) do
          {:ok, pid} ->
            # Register path for symbolic lookup
            CMS.SymbolicIndex.register_path(path, pid)
            :ok
          _ -> :ok
        end
        
        uuid

      {:error, _reason} ->
        nil
    end
  end

  # Generate a meaningful summary for a directory based on its contents
  defp generate_directory_summary(path) do
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
    
    # Call Ollama for summarization
    case CMS.Infrastructure.OllamaBridge.summarize(prompt, "qwen3:0.6b", path) do
      {:ok, %{"summary" => s, "concepts" => c}} when is_binary(s) and is_list(c) ->
        {:ok, {s, c}}
      {:ok, %{"summary" => s}} when is_binary(s) ->
        {:ok, {s, [dir_name, "Directory"]}}
      {:error, reason} ->
        Logger.error("DirectoryAgent: Ollama summarization failed for #{path}: #{inspect(reason)}")
        {:error, reason}
      other ->
        Logger.error("DirectoryAgent: Unexpected Ollama response for #{path}: #{inspect(other)}")
        {:error, :unexpected_response}
    end
  end

  defp update_edges(my_uuid, children_uuids) do
    case :mnesia.dirty_read(:nodes_table, my_uuid) do
      [{_table, _uuid, _hash, _pid, head, body, tail, stack, provenance, antenna}] ->
        new_tail = Enum.reduce(children_uuids, tail, fn child_id, acc ->
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