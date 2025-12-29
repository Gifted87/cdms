defmodule CMS.Ingestion.Crawler do
  @moduledoc """
  Handles the physical traversal of directories and files, orchestrating the creation
  of the graph hierarchy (Directory -> File Source -> Chunks).
  """

  alias CMS.Ingestion.{MimeGuard, Shredder}
  alias CMS.IngestionEngine
  alias CMS.Edge
  alias CMS.NodeSupervisor
  require Logger

  @doc """
  Traverses a directory at the given path and ingests its structure and content.
  Returns {:ok, root_node_id} on success.
  """
  def crawl(path) do
    cond do
      File.dir?(path) ->
        Logger.info("Crawler: Starting directory traversal at #{path}")
        traverse_dir(path, nil)

      File.exists?(path) ->
        Logger.info("Crawler: Starting single-file ingestion for #{path}")
        ingest_file(path, nil)

      true ->
        Logger.error("Crawler: Path does not exist or is not accessible: #{path}")
        {:error, :not_found}
    end
  end

  defp traverse_dir(path, parent_id) do
    dir_name = Path.basename(path)
    
    # 1. Ingest Directory Node
    case ingest_directory(path, dir_name, parent_id) do
      {:ok, dir_id} ->
        # 2. List contents
        case File.ls(path) do
          {:ok, files} ->
            Enum.each(files, fn file ->
              full_path = Path.join(path, file)
              if File.dir?(full_path) do
                 traverse_dir(full_path, dir_id)
              else
                 ingest_file(full_path, dir_id)
              end
            end)
            {:ok, dir_id}
          {:error, reason} ->
            Logger.error("Failed to list directory #{path}: #{inspect(reason)}")
            {:error, reason}
        end
        
      error -> 
        Logger.error("Failed to ingest directory #{path}: #{inspect(error)}")
        error
    end
  end

  defp ingest_directory(path, name, parent_id) do
    description_payloads = [
      %CMS.DataBodyPayload.Object{
        type: :object, 
        object_type: :directory, 
        data: %{path: path, name: name}
      }
    ]
    
    fact_text = "Directory: #{name}"
    
    provenance = %{source: "CMS.Ingestion.Crawler", type: "directory", path: path}
    
    request = %{
      description_payloads: description_payloads,
      fact_text: fact_text,
      agent_id: "system",
      acls: %{read: ["public"], write: ["system", "root"]},
      provenance: provenance
    }

    case IngestionEngine.ingest(request) do
      {:ok, node_id} ->
        link_parent_child(parent_id, node_id)
        {:ok, node_id}
      {:ok, :ingested_with_conflict_resolution, node_id} ->
        link_parent_child(parent_id, node_id)
        {:ok, node_id}
      err -> err
    end
  end
  
  defp ingest_file(path, parent_id) do
    with :ok <- MimeGuard.check(path),
         {:ok, content} <- File.read(path) do

         Logger.info("Processing file: #{path}")

         filename = Path.basename(path)
         
         # 1. Ingest Source Node
         payloads = [
           %CMS.DataBodyPayload.Object{
             type: :object,
             object_type: :file_source,
             data: %{filename: filename, path: path, size: byte_size(content)}
           }
         ]
         
         provenance = %{source: "CMS.Ingestion.Crawler", type: "file_source", path: path}
         
         request = %{
            description_payloads: payloads,
            fact_text: "File Source: #{filename}",
            agent_id: "system",
            acls: %{read: ["public"], write: ["system", "root"]},
            provenance: provenance
         }
         
         case IngestionEngine.ingest(request) do
            {:ok, source_id} -> handle_file_ingestion_success(source_id, parent_id, path, content)
            {:ok, :ingested_with_conflict_resolution, source_id} -> handle_file_ingestion_success(source_id, parent_id, path, content)
            _ -> :ignore # Failed to ingest source
         end
    else
      {:error, reason} -> 
        Logger.debug("Skipping file #{path}: #{inspect(reason)}")
        :ignore
    end
  end
  
  defp handle_file_ingestion_success(source_id, parent_id, path, content) do
    link_parent_child(parent_id, source_id)
    
    # 2. Shred and Ingest Chunks
    ext = Path.extname(path)
    strategy = if ext in ~w(.ex .exs .py .js .ts .rb .c .cpp .h .rs .go .java .cs .php .sh), do: :code, else: :text
    
    Logger.info("Shredding #{path} (Strategy: #{strategy})")

    chunks = Shredder.shred(content, strategy)
    ingest_chunks(chunks, source_id, nil, path)
  end

  defp ingest_chunks([], _source_id, _prev_chunk_id, _path), do: :ok
  
  defp ingest_chunks([chunk | rest], source_id, prev_chunk_id, path) do
    if prev_chunk_id == nil do
      Logger.info("Ingesting #{length(rest) + 1} chunks for #{path}...")
    end

    payloads = [
      %CMS.DataBodyPayload.Text{
        type: :text,
        content: chunk.content
      },
      %CMS.DataBodyPayload.Object{
        type: :object,
        object_type: :chunk_metadata,
        data: %{sequence_index: chunk.sequence_index, lines: chunk.lines, parent_file: path}
      }
    ]
    
    # The chunk content itself is the fact
    fact_text = chunk.content
    
    provenance = %{source: "CMS.Ingestion.Crawler", type: "content_chunk", parent: source_id, sequence: chunk.sequence_index}
    
    request = %{
       description_payloads: payloads,
       fact_text: fact_text,
       agent_id: "system",
       acls: %{read: ["public"], write: ["system", "root"]},
       provenance: provenance
    }
    
    chunk_id_result = 
      case IngestionEngine.ingest(request) do
        {:ok, id} -> id
        {:ok, :ingested_with_conflict_resolution, id} -> id
        _ -> nil
      end
      
    if chunk_id_result do
      # Edge: Chunk part_of File
      add_edge(chunk_id_result, source_id, :part_of, 1.0)
      
      # Edge: File contains Chunk (Optional, maybe too noisy? Let's add it for traversal)
      add_edge(source_id, chunk_id_result, :contains, 1.0)
      
      if prev_chunk_id do
        add_edge(prev_chunk_id, chunk_id_result, :next_part, 1.0)
        add_edge(chunk_id_result, prev_chunk_id, :prev_part, 1.0)
      end
      
      ingest_chunks(rest, source_id, chunk_id_result, path)
    else
      # If chunk failed, try next one?
      ingest_chunks(rest, source_id, prev_chunk_id, path)
    end
  end

  defp link_parent_child(nil, _child_id), do: :ok
  defp link_parent_child(parent_id, child_id) do
    add_edge(parent_id, child_id, :contains, 1.0)
    add_edge(child_id, parent_id, :inside_of, 1.0)
  end

  defp add_edge(source_id, target_id, type, weight) do
    edge = Edge.new(target_id, type, weight)
    
    case NodeSupervisor.get_node_pid(source_id) do
      nil -> 
        # If node not active (e.g. IngestionEngine created it but didn't start it? It says it spawns...)
        # IngestionEngine does `NodeSupervisor.start_child(node)`.
        # Just in case, we might need to wait or it might be a race condition.
        # Retry once?
        :timer.sleep(50)
        if pid = NodeSupervisor.get_node_pid(source_id) do
           GenServer.cast(pid, {:add_edge, edge})
        else
           Logger.warning("Failed to add edge #{type} from #{source_id} to #{target_id}: Node not active")
        end
      pid ->
        GenServer.cast(pid, {:add_edge, edge})
    end
  end
end
