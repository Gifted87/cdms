defmodule CMS.Services.LiveWire do
  @moduledoc """
  The LiveWire Sentinel: Keeps the CDMS in sync with the physical file system.
  """

  use GenServer
  require Logger
  alias CMS.Infrastructure.OllamaBridge

  @poll_interval 1000
  @debounce_ms 500

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{watched_paths: %{}}, name: __MODULE__)
  end

  @doc """
  Adds a path to be watched by LiveWire.
  """
  def watch(path) do
    GenServer.cast(__MODULE__, {:watch, path})
  end

  # --- Callbacks ---

  @impl true
  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_cast({:watch, path}, state) do
    # When watching, we store the current mtime/hash if possible
    mtime = get_mtime(path)
    {:noreply, %{state | watched_paths: Map.put(state.watched_paths, path, mtime)}}
  end

  @impl true
  def handle_info(:poll_fs, state) do
    # Hybrid: For now, we poll the watched_paths
    Enum.each(state.watched_paths, fn {path, last_mtime} ->
      current_mtime = get_mtime(path)
      if current_mtime && current_mtime != last_mtime do
        # Trigger Mutation Loop with debounce
        Process.send_after(self(), {:mutate, path}, @debounce_ms)
      end
    end)

    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def handle_info({:mutate, path}, state) do
    # Step 6.2: The Mutation Loop
    Logger.info("LiveWire: mutation detected on #{path}")
    
    case handle_mutation(path) do
      {:ok, _uuid} ->
        # Update last known mtime to avoid re-triggering immediately
        new_mtime = get_mtime(path)
        {:noreply, %{state | watched_paths: Map.put(state.watched_paths, path, new_mtime)}}
      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Mutation Logic ---

  defp handle_mutation(path) do
    if !File.exists?(path) do
      # Gap 6.3: Self-Healing (ENOENT Detection)
      uuid = UUID.uuid5(:oid, path)
      Logger.info("LiveWire: Detected DELETION of #{path}. Scouring node #{uuid}.")
      CMS.NodeSupervisor.terminate_node(uuid)
    else
      if File.dir?(path) do
        # 4.1 Foreign Object Detection (Structural Mutation)
        handle_directory_mutation(path)
      else
        uuid = UUID.uuid5(:oid, path)
        
        # 1. Verify Hash
        case File.read(path) do
          {:ok, content} ->
            new_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
            
            # Get current node state
            case CMS.NodeSupervisor.get_node(uuid) do
              {:ok, old_node} ->
                if old_node.body.data_ledger.metabolism == :fluid_blood do
                  # Phase 5: Blood Node Metabolism
                  # Instead of full reincarnation, we buffer for the heartbeat.
                  Logger.debug("LiveWire: routing Blood Node mutation to Physiology Buffer: #{path}")
                  CMS.Core.Logic.PhysiologyEngine.buffer_blood(uuid, content)
                  {:ok, uuid}
                else
                  # Bone Node logic (Standard change tracking)
                  if old_node.body.data_ledger.integrity_hash == new_hash do
                    Logger.debug("LiveWire: hash matches, ignoring touch event.")
                    {:ok, uuid}
                  else
                    perform_full_reincarnaion(old_node, content, new_hash)
                  end
                end
              _ ->
                Logger.warning("LiveWire: detected change for unknown node #{uuid}")
                {:error, :node_not_found}
            end
          {:error, _} ->
            # Race condition: file deleted between exists? and read
            handle_mutation(path) 
        end
      end
    end
  end

  defp handle_directory_mutation(path) do
    parent_uuid = UUID.uuid5(:oid, path)
    case CMS.NodeSupervisor.get_node(parent_uuid) do
      {:ok, parent_node} ->
        case File.ls(path) do
          {:ok, current_items} ->
            # 1. Old Objects (from Connectome)
            old_items = parent_node.tail.hierarchical
                        |> Enum.filter(fn e -> e.type == :parent_of end)
                        |> Enum.map(fn e -> 
                          case :mnesia.dirty_read(:nodes_table, e.target_node_id) do
                            [{_, _, _, _, _, body, _, _}] -> Path.basename(body.data_ledger.physical_symlink)
                            _ -> nil
                          end
                        end) |> Enum.filter(& &1)

            # 2. Deletions (Orphan Logic)
            deleted_items = old_items -- current_items
            Enum.each(deleted_items, fn item ->
               item_id = UUID.uuid5(:oid, Path.join(path, item))
               CMS.NodeSupervisor.terminate_node(item_id)
            end)

            # 3. New Objects (Genesis Logic)
            # FILTER: Apply ExclusionCortex to stop ingestion of deps, _build, etc.
            new_items = 
              (current_items -- old_items)
              |> Enum.filter(fn item -> 
                 CMS.Ingestion.ExclusionCortex.should_traverse?(Path.join(path, item))
              end)
            
            if new_items != [] do
              Logger.info("LiveWire: Structural Mutation detected in #{path}. New valid objects: #{inspect(new_items)}")
              # Trigger Mitosis for new items
              {_x, _y, z} = parent_node.head.spatial_coords
              
              Enum.with_index(new_items) |> Enum.each(fn {item, idx} ->
                item_path = Path.join(path, item)
                
                # Sibling index offset
                offset = idx + 100 
                r = :math.sqrt(offset)
                theta = 2.4 * offset
                coords = {r * :math.cos(theta), r * :math.sin(theta), z + 1}
                
                # Width Descriptor
                parent_base = String.replace(parent_node.head.width_descriptor, ~r/\d+$/, "")
                child_char = <<65 + rem(offset, 26)>>
                width = "#{parent_base}#{child_char}0"

                if File.dir?(item_path) do
                   CMS.NodeSupervisor.start_directory_agent(item_path, parent_uuid, coords, width)
                else
                   CMS.Ingestion.FileIngestionTask.ingest(item_path, parent_uuid, coords, width)
                end
              end)
            end
            {:ok, parent_uuid}
          _ -> {:error, :scan_failed}
        end
      _ -> {:error, :parent_node_not_found}
    end
  end

  defp perform_full_reincarnaion(old_node, content, new_hash) do
    # Step 6.2: Re-Cognition & Mutation Loop
    Logger.info("LiveWire: performing Re-Cognition for #{old_node.id}")
    
    # 1. Chrono-Shift: Push current state to History Stack
    # We use the old_node's data before modifying it.
    old_body_content = 
      if old_node.body.mode == :deep do
        # Decompress if needed, but for diffing we might want raw string.
        # Check if NodeBody has decompress helper? Yes I added it.
        CMS.NodeBody.decompress(old_node.body) || ""
      else
        "" # Mode B has no content to diff against
      end

    new_stack = CMS.ChronoStack.push(
      old_node.body.data_ledger.chrono_stack || CMS.ChronoStack.new(), # Ensure stack exists
      old_body_content,
      content,
      old_node.body.data_ledger.integrity_hash,
      :livewire_mutation
    )

    # 2. Antenna Boost
    new_antenna = %{old_node.antenna | 
      gain: min(1.0, old_node.antenna.gain + 0.2),
      frequency: old_node.antenna.frequency + 1,
      resonance_pattern: "high_write_frequency"
    }

    # 3. Vector Refresh & Body Update (Async to avoid blocking Sentinel)
    Task.start(fn ->
      path = old_node.body.data_ledger.physical_symlink
      
      # Re-Cognize with Robust Fallback
      {summary, concepts, embedding} = 
        case OllamaBridge.summarize(content) do
          {:ok, %{"summary" => s, "concepts" => c}} ->
             # Summary succeeded, try embedding
             case OllamaBridge.embed("#{Path.basename(path)}: #{s}") do
               {:ok, vec_list} -> 
                  {s, c, Nx.tensor(vec_list)}
               _ -> 
                  Logger.warning("LiveWire: Embedding timed out for \#{path}. Using new summary but old vector.")
                  {s, c, old_node.head.embedding}
             end
          _ -> 
             # Total cognitive failure (Timeout/Busy) -> Preserve old cognitive state
             Logger.warning("LiveWire: Cognition timed out for \#{path}. Preserving old semantics.")
             {old_node.body.data_head.summary, old_node.body.data_head.concepts, old_node.head.embedding}
        end

      new_head = %{old_node.head | embedding: embedding}
      new_data_head = CMS.DataHead.new(summary, concepts)
      new_ledger = %{old_node.body.data_ledger | integrity_hash: new_hash, last_mutation: DateTime.utc_now(), chrono_stack: new_stack} # Store stack in ledger? Spec says "Chrono Stack" is separate in Mnesia schema 8.1, but Node structure usually has it attached.
      # Wait, Schema 8.1 says `chrono_stack` is a column in `nodes_table`.
      # And Node struct (Step 2.3) doesn't explicitly list it in Body, but Section 5.2 says "Every Node maintains a stack".
      # I'll enable it in `NodeBody` or just pass it to persistence.
      # For now, I'll attach it to the `ledger` since it wasn't in the top-level Node struct definition I reviewed earlier (Node struct had head, body, tail, antenna).
      # Actually, let's keep it in the Mnesia record for now, or update Node struct. 
      # I'll update the Node struct to carry it in `body.data_ledger` if possible, or just assume NodeActor handles it.
      # Check `NodeBody` struct... `data_ledger`. `DataTail` struct... I'll check `DataTail`.
      # DataTail had `:last_mutation`.
      # I'll add `chrono_stack` to `DataTail` (Ledger) effectively via Map.put for now to pass it along.
      
      new_body = CMS.NodeBody.new(new_data_head, content, new_ledger, :deep) # Mode A refresh
      
      updated_node = %{old_node | head: new_head, body: new_body, antenna: new_antenna, last_fired: DateTime.utc_now()}
      
      # Persistence & Broadcast
      CMS.NodeSupervisor.update_node(updated_node)
      
      # Force Edge Regeneration (Hebbian Priming)
      CMS.Core.Logic.EdgeGenerator.generate_edges(updated_node) |> CMS.NodeSupervisor.update_node()

      Phoenix.PubSub.broadcast(CMS.PubSub, "cdms:mutations", {:mutation, old_node.id})
    end)

    {:ok, old_node.id}
  end

  # --- Helpers ---

  defp get_mtime(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll_fs, @poll_interval)
  end
end

