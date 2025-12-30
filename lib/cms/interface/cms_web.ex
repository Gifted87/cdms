defmodule CMS.Web do
  @moduledoc """
  The Universal API Layer for the CMS.

  Provides a unified HTTP and WebSocket interface to the Cognitive Memory System.
  Designed to be dropped into the supervision tree with minimal configuration.

  ## Security & Performance Features
  - **Safe Atom Handling**: Whitelisted atom creation to prevent DoS.
  - **Input Validation**: Strict FID schema validation via FIDValidator.
  - **Optimized Reads**: Prefers active GenServer state over expensive disk logs.
  - **Size Limits**: Enforced 10MB body limit.
  - **WS Auth**: Basic token check for real-time streams.
  - **Resiliency**: Implements Global Fallback Broadcast if targeted search fails.

  ## Endpoints
  - POST /api/v1/ingest             -> Ingest new knowledge
  - POST /api/v1/query              -> Semantic/Temporal Search (Live or Historical)
  - GET  /api/v1/nodes/:id          -> Fetch active node state
  - POST /api/v1/nodes/:id/feedback -> Anti-Hebbian Penalization (NEW)
  - GET  /api/v1/nodes/:id/edges    -> Fetch node relationships
  - GET  /api/v1/nodes/:id/history  -> Temporal "Time Travel" fetch
  - GET  /api/v1/health/embedder    -> Check ML Bridge status
  - WS   /api/v1/events             -> Real-time signals (WebSocket)
  """
  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
    def init(opts) do
      port = Keyword.get(opts, :port, 4000)

      # 1. Define routes explicitly
      ws_route = "/api/v1/events"

      # 2. Define the dispatch table
      # Plug.Cowboy will do it automatically. Passing a compiled table causes the crash.
      dispatch = [
        {:_, [
          {ws_route, CMS.Web.SocketHandler, []},
          {:_, Plug.Cowboy.Handler, {CMS.Web.Router, []}}
        ]}
      ]

      children = [
        # Pass the raw list 'dispatch' to options
        {Plug.Cowboy, scheme: :http, plug: CMS.Web.Router, options: [port: port, dispatch: dispatch]}
      ]

      Logger.info("CMS.Web API started on port #{port}")
      Supervisor.init(children, strategy: :one_for_one)
    end

  def normalize_acls(nil), do: %{read: ["public"], write: ["system", "root"]}
  def normalize_acls(list) when is_list(list), do: %{read: list ++ ["public"], write: list}
  def normalize_acls(map) when is_map(map), do: map
  def normalize_acls(_), do: %{read: ["public"], write: ["system", "root"]}
end

# ==============================================================================
# REST ROUTER
# ==============================================================================
defmodule CMS.Web.Router do
  use Plug.Router
  require Logger

  alias CMS.{IngestionEngine, QueryCoordinator, TemporalQueryEngine, NodeSupervisor}
  alias CMS.{DataBodyPayload, FIDValidator, Tool.Embedder}
  alias CMS.Ingestion.Orchestrator

  plug Plug.Logger
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 100_000_000

  plug :match
  plug :dispatch

  # --- COGNITIVE ARTIFACT BUILDER ---
  # Returns a structured "Cognitive Artifact" with identity, anatomy, history, and relationships
  
  defp build_cognitive_artifact(score, node, _opts \\ []) when is_map(node) do
    # Extract node data safely using pattern matching for structs and Map.get for fallback
    node_id = case node do
      %CMS.Node{id: id} -> id
      %{id: id} -> id
      %{"id" => id} -> id
      _ -> Map.get(node, :id) || Map.get(node, "id")
    end
    
    # Get path from body.data_ledger - use safe struct access
    path = case node do
      %CMS.Node{body: %{data_ledger: %{physical_symlink: symlink}}} when is_binary(symlink) ->
        symlink
      %{body: %{data_ledger: %{physical_symlink: symlink}}} when is_binary(symlink) ->
        symlink
      %{"body" => %{"data_ledger" => %{"physical_symlink" => symlink}}} when is_binary(symlink) ->
        symlink
      _ ->
        "unknown"
    end
    
    name = if path != "unknown", do: Path.basename(path), else: "unknown"
    
    # Get PID if available
    pid = case CMS.NodeSupervisor.get_node_pid(node_id) do
      nil -> nil
      pid when is_pid(pid) -> inspect(pid)
      _ -> nil
    end
    
    # Determine mode
    mode = case node do
      %CMS.Node{body: %{mode: m}} -> m
      %{body: %{mode: m}} -> m
      %{"body" => %{"mode" => m}} -> m
      _ -> :shallow
    end
    
    # Get hash
    hash = case node do
      %CMS.Node{body: %{data_ledger: %{integrity_hash: h}}} when is_binary(h) ->
        h
      %{body: %{data_ledger: %{integrity_hash: h}}} when is_binary(h) ->
        h
      %{"body" => %{"data_ledger" => %{"integrity_hash" => h}}} when is_binary(h) ->
        h
      _ ->
        "unknown"
    end
    
    # Get content if node is in deep mode (has stored content)
    content = if mode == :deep do
      case node do
        %CMS.Node{body: body} -> CMS.NodeBody.decompress(body)
        %{body: %{data_body: db}} -> db
        _ -> nil
      end
    else
      nil
    end
    
    # Calculate size
    size = cond do
      is_binary(content) -> byte_size(content)
      is_nil(content) ->
        case node do
          %{body: %{data_ledger: %{size: s}}} when is_integer(s) -> s
          _ -> 0
        end
      true -> # Structured content (e.g. Meta-Node list)
        byte_size(Jason.encode!(content))
    end
    
    # Get history info
    chrono_stack = case node do
      %{body: %{data_ledger: %{chrono_stack: cs}}} -> cs
      %{"body" => %{"data_ledger" => %{"chrono_stack" => cs}}} -> cs
      _ -> %{snapshots: []}
    end
    
    stack_depth = case chrono_stack do
      %{snapshots: snaps} when is_list(snaps) -> length(snaps)
      %{"snapshots" => snaps} when is_list(snaps) -> length(snaps)
      _ -> 0
    end
    
    last_mutation = case node do
      %{body: %{data_ledger: %{last_mutation: lm}}} -> lm
      %{"body" => %{"data_ledger" => %{"last_mutation" => lm}}} -> lm
      %{created_at: ca} -> ca
      %{"created_at" => ca} -> ca
      _ -> nil
    end
    
    mutation_cause = if stack_depth > 0 do
      snapshots = case chrono_stack do
        %{snapshots: snaps} -> snaps
        %{"snapshots" => snaps} -> snaps
        _ -> []
      end
      
      case List.first(snapshots) do
        %{cause: c} -> c
        %{"cause" => c} -> c
        _ -> "genesis"
      end
    else
      "genesis"
    end
    
    # Get relationships from tail
    tail = case node do
      %CMS.Node{tail: t} -> t
      %{tail: t} -> t
      %{"tail" => t} -> t
      _ -> nil
    end
    
    relationships = if tail do
      extract_relationships(tail)
    else
      []
    end
    
    # Build the Cognitive Artifact
    artifact = %{
      score: score,
      identity: %{
        path: path,
        name: name,
        node_id: node_id,
        pid: pid
      },
      anatomy: %{
        mode: mode,
        size: size,
        hash: hash
      },
      history: %{
        current_version: stack_depth + 1,
        last_mutation: format_timestamp(last_mutation),
        mutation_cause: mutation_cause,
        chrono_stack_depth: stack_depth
      },
      relationships: relationships
    }
    
    # Add content only if requested and available
    if content do
      put_in(artifact, [:anatomy, :content], content)
    else
      artifact
    end
  end
  
  defp extract_relationships(tail) when is_map(tail) do
    # Extract from NodeTail structure - use Map.get to avoid Access behaviour issues
    hierarchical = Map.get(tail, :hierarchical) || Map.get(tail, "hierarchical") || []
    syntactic = Map.get(tail, :syntactic) || Map.get(tail, "syntactic") || []
    semantic = Map.get(tail, :semantic) || Map.get(tail, "semantic") || []
    
    all_edges = hierarchical ++ syntactic ++ semantic
    
    Enum.map(all_edges, fn edge ->
      %{
        type: Map.get(edge, :type) || Map.get(edge, "type"),
        target: Map.get(edge, :target_node_id) || Map.get(edge, "target_node_id"),
        weight: Map.get(edge, :weight) || Map.get(edge, "weight") || 1.0
      }
    end)
    |> Enum.take(20)  # Limit to top 20 relationships for response size
  end
  
  defp format_timestamp(nil), do: "unknown"
  defp format_timestamp(dt) when is_binary(dt), do: dt
  defp format_timestamp(%DateTime{} = dt) do
    seconds_ago = DateTime.diff(DateTime.utc_now(), dt, :second)
    cond do
      seconds_ago < 60 -> "#{seconds_ago} seconds ago"
      seconds_ago < 3600 -> "#{div(seconds_ago, 60)} minutes ago"
      seconds_ago < 86400 -> "#{div(seconds_ago, 3600)} hours ago"
      true -> "#{div(seconds_ago, 86400)} days ago"
    end
  end
  defp format_timestamp(_), do: "unknown"

  defp is_directory?(node) do
    # Check mime type in data_ledger or provenance
    mime = case node do
      %CMS.Node{body: %{data_ledger: %{mime_definition: mime}}} -> mime
      %{body: %{data_ledger: %{mime_definition: mime}}} -> mime
      %{"body" => %{"data_ledger" => %{"mime_definition" => mime}}} -> mime
      _ -> nil
    end

    type = case node do
      %CMS.Node{provenance: %{"type" => t}} -> t
      %{provenance: %{"type" => t}} -> t
      %{"provenance" => %{"type" => t}} -> t
      _ -> nil
    end

    mime == "inode/directory" or type == "directory"
  end

  # ----------------------------------------------------------------------------
  # 1. INGESTION API
  # ----------------------------------------------------------------------------
  post "/api/v1/ingest/blob" do
    text = conn.body_params["text"]
    meta = conn.body_params["metadata"] || %{}
    filename = meta["filename"] || "blob.txt"
    
    if text do
       tmp_path = Path.join(System.tmp_dir!(), "#{UUID.uuid4()}_#{filename}")
       File.write!(tmp_path, text)
       
       _task = Orchestrator.start_ingestion(tmp_path)
       send_json(conn, 202, %{status: "accepted", job_id: "async_ingest"})
    else
       send_json(conn, 400, %{error: "Missing text field"})
    end
  end

  post "/api/v1/ingest/upload" do
    case conn.body_params["file"] do
      %Plug.Upload{path: tmp_path, filename: filename} ->
         if Path.extname(filename) == ".zip" do
            dest = Path.join(System.tmp_dir!(), "#{UUID.uuid4()}_extracted")
            File.mkdir!(dest)
            # Use Erlang zip module
            case :zip.unzip(String.to_charlist(tmp_path), [{:cwd, String.to_charlist(dest)}]) do
               {:ok, _} ->
                  Orchestrator.start_ingestion(dest)
                  send_json(conn, 202, %{status: "accepted", type: "zip"})
               {:error, reason} ->
                  send_json(conn, 400, %{error: "Zip extraction failed", details: inspect(reason)})
            end
         else
            new_path = Path.join(System.tmp_dir!(), "#{UUID.uuid4()}_#{filename}")
            File.cp!(tmp_path, new_path)
            Orchestrator.start_ingestion(new_path)
            send_json(conn, 202, %{status: "accepted", type: "file"})
         end
      _ ->
         send_json(conn, 400, %{error: "No file provided"})
    end
  end

  post "/api/v1/ingest" do
    with {:ok, params} <- validate_params(conn.body_params, ["fact_text", "description_payloads", "agent_id"]),
         {:ok, payloads} <- parse_and_validate_payloads(params["description_payloads"]),
         acls <- CMS.Web.normalize_acls(params["acls"]) do

      request = %{
        fact_text: params["fact_text"],
        description_payloads: payloads,
        agent_id: params["agent_id"],
        acls: acls,
        provenance: params["provenance"] || %{}
      }

      case IngestionEngine.ingest(request) do
        {:ok, node_id} ->
          send_json(conn, 201, %{status: "ok", node_id: node_id})
        {:ok, :ingested_with_conflict_resolution, meta_id} ->
          send_json(conn, 202, %{status: "conflict_resolved", meta_node_id: meta_id})
        {:error, :permission_denied} ->
          send_json(conn, 403, %{error: "Permission denied"})
        {:error, reason} ->
          Logger.error("Ingestion failed: #{inspect(reason)}")
          send_json(conn, 500, %{error: "Ingestion failed", detail: inspect(reason)})
      end
    else
      {:error, {:validation, msg}} -> send_json(conn, 400, %{error: "Validation Error", detail: msg})
      {:error, missing} when is_binary(missing) -> send_json(conn, 400, %{error: "Missing fields: #{missing}"})
      _ -> send_json(conn, 400, %{error: "Invalid request format"})
    end
  end

  # ----------------------------------------------------------------------------
  # 2. QUERY API (Live & Temporal) - NOW WITH THREE-GATE TRIAGE
  # ----------------------------------------------------------------------------
  
  post "/api/v1/query/unified" do
    # NEW: Unified query with automatic triage
    params = conn.body_params
    query_string = params["query"]
    
    if is_nil(query_string) do
      send_json(conn, 400, %{error: "Must provide 'query' field"})
    else
      opts = [
        mode: safe_atom_cast(params["mode"], nil, [:symbolic, :nominal, :semantic, :auto]),
        model: params["embedding_model"] || "all-MiniLM-L6-v2",
        threshold: params["threshold"] || 0.35,
        max_results: params["max_results"]
      ]
      
      case CMS.QueryTriage.execute(query_string, opts) do
        {:ok, mode_used, results} ->
          formatted = 
            results
            |> Enum.reject(fn
              %{node: node} -> is_directory?(node)
              node -> is_directory?(node)
            end)
            |> Enum.map(fn
              %{node: node, score: score} -> build_cognitive_artifact(score, node)
              %{} = node -> build_cognitive_artifact(1.0, node)
              node -> build_cognitive_artifact(1.0, node)
            end)
          
          send_json(conn, 200, %{
            mode_used: mode_used,
            query: query_string,
            count: length(formatted),
            results: formatted
          })
        
        {:error, reason} ->
          send_json(conn, 500, %{error: "Query failed", detail: inspect(reason)})
      end
    end
  end

  post "/api/v1/query" do
    params = conn.body_params
    query_text = params["query_text"]
    query_vec = params["query_vector"]
    agent_id = params["agent_id"] || "anonymous"

    # Feature: Pagination & Thresholds
    max_results = params["max_results"]
    min_relevance = params["min_relevance"] || 0.35

    if is_nil(query_text) and is_nil(query_vec) do
      send_json(conn, 400, %{error: "Must provide query_text or query_vector"})
    else
      try do
        model = params["embedding_model"] || "all-MiniLM-L6-v2"

        final_vec =
          if query_vec do
             Nx.tensor(query_vec)
          else
             case Embedder.generate(query_text, model) do
               {:ok, tensor} -> tensor
               {:error, _} -> throw(:embedding_failed)
             end
          end

        # Feature: Validated Region Targeting
        target_regions = resolve_target_regions(params["target_regions"], final_vec, model)

        # Feature: Temporal Search (as_of)
        case params["as_of"] do
          nil ->
            # A. LIVE SPREADING ACTIVATION
            execute_live_query(conn, %{
              query_vector: final_vec,
              query_text: query_text,
              target_regions: target_regions,
              agent_id: agent_id,
              model: model,
              params: params
            })

          iso_timestamp ->
             # B. HISTORICAL FORENSIC SEARCH
             case DateTime.from_iso8601(iso_timestamp) do
               {:ok, dt, _} ->
                 execute_temporal_search(conn, final_vec, model, dt, max_results, min_relevance)
               _ ->
                 send_json(conn, 400, %{error: "Invalid as_of timestamp format"})
             end
        end

      catch
        :embedding_failed -> send_json(conn, 503, %{error: "Embedding service unavailable"})
        e ->
          Logger.error("Query Error: #{inspect(e)}")
          send_json(conn, 500, %{error: "Internal Query Error"})
      end
    end
  end

  defp resolve_target_regions(input, vector, model) when is_list(input) do
    # Validate user input: Must be list of integers 0..255
    if Enum.all?(input, fn x -> is_integer(x) and x >= 0 and x <= 255 end) do
      input
    else
      # If invalid, fall back to computed region but log warning
      Logger.warning("Invalid target_regions provided, falling back to computed.")
      [CMS.SemanticRegion.compute_region_hash(vector, model)]
    end
  end
  # Fallback: Compute region if input is nil
  defp resolve_target_regions(_, vector, model) do
    [CMS.SemanticRegion.compute_region_hash(vector, model)]
  end

  # --- CRITICAL UPDATE: Implements Decentralized Query with Broadcast to All Nodes ---
  defp execute_live_query(conn, ctx) do
    query_id = UUID.uuid4()

    # Base Context
    query_context = %{
      query_id: query_id,
      query_vector: ctx.query_vector,
      query_text: ctx.query_text,
      agent_id: ctx.agent_id,
      trace: MapSet.new(),
      embedding_model: ctx.model,
      min_relevance: ctx.params["min_relevance"] || 0.35,
      reasoning_mode: safe_atom_cast(ctx.params["reasoning_mode"], :normal, [:normal, :brainstorm, :precision]),
      system_mode: safe_atom_cast(ctx.params["system_mode"], :normal, [:normal, :emergency])
    }

    # NEW: Start a coordinator to collect responses from nodes that fire
    # Pass max_results if specified
    coord_opts = if ctx.params["max_results"], do: [max_results: ctx.params["max_results"]], else: []
    {:ok, coord_pid} = QueryCoordinator.start_link(query_id, [0], self(), coord_opts)
    ref = Process.monitor(coord_pid)

    # CRITICAL FIX: Wait for the coordinator to signal that it's ready/registered.
    # This prevents the race condition where nodes fire and try to report results
    # before the Coordinator is findable in the Registry.
    receive do
      {:coordinator_ready, ^query_id} ->
        Logger.debug("WebRouter: Coordinator #{query_id} confirmed ready. Dispatching broadcast.")
        # NEW: Broadcast query to ALL nodes using the decentralized coordinator
        CMS.BroadcastCoordinator.broadcast_query(query_context)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        Logger.error("WebRouter: Coordinator crashed before ready signal.")
        # We will fall through to the result receiver which will handle the DOWN message
    after
      2000 ->
        Logger.error("WebRouter: Timed out waiting for Coordinator #{query_id} ready signal.")
    end

    # Wait for results with timeout
    results =
      receive do
        {:query_result, ^query_id, received_results} ->
          Process.demonitor(ref, [:flush])
          received_results
        {:DOWN, ^ref, :process, _pid, _reason} ->
          []
      after 10000 -> # 10 second timeout for global broadcast
          Process.demonitor(ref, [:flush])
          []
      end

    # Transform tuples {score, node} to Maps %{score: s, node: n} for JSON encoding
    trimmed_results =
      results
      |> Enum.reject(fn {_score, node} -> is_directory?(node) end)
      |> Enum.map(fn {score, node} -> build_cognitive_artifact(score, node) end)

    send_json(conn, 200, %{
      query_id: query_id,
      count: length(trimmed_results),
      results: trimmed_results,
      fallback_triggered: false # No fallback needed in new model
    })
  end

  defp execute_temporal_search(conn, vector, _model, dt, max_results, min_relevance) do
    # 1. Fetch the reconstructed history from the Engine
    case CMS.TemporalQueryEngine.get_system_state_at_time(dt) do
      {:ok, nodes} ->
        # 2. Brute-force Vector Scan in Memory
        results =
          nodes
          |> Enum.map(fn node ->
            # Extract embedding safely (it will be a list of floats from JSON)
            node_embedding = get_in(node, ["head", "embedding"])

            if node_embedding do
              # Convert list back to tensor for math
              tensor_emb = if is_list(node_embedding), do: Nx.tensor(node_embedding), else: node_embedding
              score = cosine_similarity(vector, tensor_emb)
              {score, node}
            else
              {0.0, node}
            end
          end)
          |> Enum.filter(fn {score, _} -> score >= min_relevance end)
          |> Enum.reject(fn {_score, node} -> is_directory?(node) end)
          |> Enum.sort_by(fn {score, _} -> score end, :desc)
          |> Enum.take(max_results)
          |> Enum.map(fn {score, node} -> build_cognitive_artifact(score, node) end)

        send_json(conn, 200, %{
          query_type: "temporal",
          as_of: DateTime.to_iso8601(dt),
          count: length(results),
          results: results
        })

      _ ->
        send_json(conn, 500, %{error: "Failed to reconstruct history"})
    end
  end

  defp cosine_similarity(vec_a, vec_b) do
    try do
      # Handle both Tensors and Lists
      list_a = if is_struct(vec_a, Nx.Tensor), do: Nx.to_flat_list(vec_a), else: vec_a
      list_b = if is_struct(vec_b, Nx.Tensor), do: Nx.to_flat_list(vec_b), else: vec_b

      dot_product = Enum.zip(list_a, list_b) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
      norm_a = :math.sqrt(Enum.map(list_a, &(&1 * &1)) |> Enum.sum())
      norm_b = :math.sqrt(Enum.map(list_b, &(&1 * &1)) |> Enum.sum())

      if norm_a == 0 or norm_b == 0, do: 0.0, else: dot_product / (norm_a * norm_b)
    rescue
      _ -> 0.0
    end
  end

  defp fetch_active_or_historical_node(node_id) do
    if pid = CMS.NodeSupervisor.get_node_pid(node_id) do
      try do
        GenServer.call(pid, :get_state_snapshot, 1000)
      rescue _ -> nil end
    else
      # If not active, try to fetch the LATEST known state from history
      case CMS.TemporalQueryEngine.get_node_state_at_time(node_id, DateTime.utc_now()) do
        {:ok, node} -> node
        _ -> nil
      end
    end
  end

  # ----------------------------------------------------------------------------
  # 3. NODE MANAGEMENT API
  # ----------------------------------------------------------------------------
  
  # NEW: Chrono-Forensics Feature 1 - Stack Traversal
  get "/api/v1/nodes/:id/chrono" do
    id = conn.path_params["id"]
    params = fetch_query_params(conn).query_params
    depth = String.to_integer(params["depth"] || "10")
    
    case CMS.TemporalQueryEngine.get_node_history(id, depth: depth) do
      {:ok, snapshots} ->
        send_json(conn, 200, %{
          node_id: id,
          depth: depth,
          snapshot_count: length(snapshots),
          snapshots: snapshots
        })
      {:error, :node_not_found} ->
        send_json(conn, 404, %{error: "Node not found"})
      {:error, reason} ->
        send_json(conn, 500, %{error: "Failed to retrieve history", detail: inspect(reason)})
    end
  end
  
  # NEW: Chrono-Forensics Feature 2 - Differential Diagnosis
  get "/api/v1/mutations" do
    params = fetch_query_params(conn).query_params
    since = params["since"] || "60"
    
    # Parse time range (supports "60m", "2h", "1d")
    minutes = parse_time_range(since)
    
    case CMS.TemporalQueryEngine.find_recent_mutations(minutes) do
      {:ok, mutations} ->
        send_json(conn, 200, %{
          since: "#{minutes} minutes ago",
          count: length(mutations),
          mutations: mutations
        })
      {:error, reason} ->
        send_json(conn, 500, %{error: "Failed to find mutations", detail: inspect(reason)})
    end
  end
  
  # NEW: Chrono-Forensics Feature 3 - Directory State Reconstruction
  get "/api/v1/reconstruct" do
    params = fetch_query_params(conn).query_params
    path = params["path"]
    as_of = params["as_of"]
    
    if is_nil(path) or is_nil(as_of) do
      send_json(conn, 400, %{error: "Must provide 'path' and 'as_of' query parameters"})
    else
      case DateTime.from_iso8601(as_of) do
        {:ok, dt, _} ->
          case CMS.TemporalQueryEngine.reconstruct_directory_state(path, dt) do
            {:ok, state} ->
              send_json(conn, 200, state)
            {:error, reason} ->
              send_json(conn, 500, %{error: "Reconstruction failed", detail: inspect(reason)})
          end
        _ ->
          send_json(conn, 400, %{error: "Invalid as_of timestamp format"})
      end
    end
  end
  
  get "/api/v1/nodes/:id" do
    id = conn.path_params["id"]
    case fetch_active_or_historical_node(id) do
      nil -> send_json(conn, 404, %{error: "Node not found in active memory or history"})
      node -> send_json(conn, 200, node)
    end
  end

  # Feature: Anti-Hebbian Feedback
  post "/api/v1/nodes/:id/feedback" do
    id = conn.path_params["id"]
    params = conn.body_params

    # Validate Penalization Amount
    amount = params["penalization_amount"]
    context_id = params["context_id"]

    if is_number(amount) and amount > 0.0 and amount <= 1.0 do
      case NodeSupervisor.get_node_pid(id) do
        nil ->
          send_json(conn, 404, %{error: "Node not active"})
        pid ->
          # Cast the feedback to the node (Gap C remediation)
          GenServer.cast(pid, {:feedback, :irrelevant, context_id, amount})
          send_json(conn, 200, %{status: "feedback_applied", node_id: id})
      end
    else
      send_json(conn, 400, %{error: "penalization_amount must be float between 0.0 and 1.0"})
    end
  end

  get "/api/v1/nodes/:id/history" do
    id = conn.path_params["id"]
    params = fetch_query_params(conn).query_params

    case DateTime.from_iso8601(params["as_of"] || "") do
      {:ok, dt, _} ->
        case TemporalQueryEngine.get_node_state_at_time(id, dt) do
          {:ok, node} -> send_json(conn, 200, node)
          {:error, _} -> send_json(conn, 404, %{error: "No history found"})
        end
      _ ->
        send_json(conn, 400, %{error: "Invalid timestamp"})
    end
  end

  get "/api/v1/nodes/:id/edges" do
    id = conn.path_params["id"]
    case NodeSupervisor.get_node_pid(id) do
      nil ->
        case TemporalQueryEngine.get_node_state_at_time(id, DateTime.utc_now()) do
          {:ok, node} ->
            # Get tail - handle both map (string keys) and struct
            tail = case node do
              %CMS.Node{tail: t} -> t
              %{tail: t} -> t
              %{"tail" => t} -> t
              _ -> nil
            end
            
            relationships = if tail, do: extract_relationships(tail), else: []
            send_json(conn, 200, %{node_id: id, edge_count: length(relationships), edges: relationships})
          _ -> send_json(conn, 404, %{error: "Node not found"})
        end
      pid ->
        try do
          # Assume node actor exposes edges via call or state snapshot
          case GenServer.call(pid, :get_state_snapshot, 5000) do
            {:ok, node} ->
              relationships = extract_relationships(node.tail)
              send_json(conn, 200, %{node_id: id, edge_count: length(relationships), edges: relationships})
            node when is_map(node) ->
              relationships = extract_relationships(node.tail)
              send_json(conn, 200, %{node_id: id, edge_count: length(relationships), edges: relationships})
            _ -> 
              send_json(conn, 503, %{error: "Invalid state from node"})
          end
        catch
          _, _ -> send_json(conn, 503, %{error: "Node busy"})
        end
    end
  end

  delete "/api/v1/nodes/:id" do
    id = conn.path_params["id"]
    agent_id = get_req_header(conn, "x-agent-id") |> List.first()

    if agent_id in ["root", "system"] do
      case NodeSupervisor.get_node_pid(id) do
        nil -> send_json(conn, 404, %{error: "Node not active"})
        pid ->
           GenServer.stop(pid, :normal)
           CMS.LogAppender.append_node_event(id, :node_decayed, %{reason: "admin_eviction", by: agent_id})
           send_json(conn, 200, %{status: "evicted"})
      end
    else
      send_json(conn, 403, %{error: "Admin privileges required"})
    end
  end

  # ----------------------------------------------------------------------------
  # 4. SYSTEM API
  # ----------------------------------------------------------------------------
  post "/api/v1/system/:action" do
    agent_id = get_req_header(conn, "x-agent-id") |> List.first()
    if agent_id not in ["root", "system"] do
       send_json(conn, 403, %{error: "Forbidden"})
    else
      case conn.path_params["action"] do
        "rotate-epoch" ->
          CMS.EpochManager.rotate_log()
          send_json(conn, 200, %{status: "rotated"})
        "check-drift" ->
          send(CMS.ModelDriftManager, :check_for_drift)
          send_json(conn, 200, %{status: "drift_check_initiated"})
        "set-congestion" ->
          level = conn.body_params["level"]
          if is_number(level) do
            CMS.ActivationEngine.set_congestion_level(level)
            send_json(conn, 200, %{status: "congestion_set", level: level})
          else
            send_json(conn, 400, %{error: "Level must be a number"})
          end
        _ ->
          send_json(conn, 404, %{error: "Unknown action"})
      end
    end
  end

  get "/api/v1/health/embedder" do
    url = "http://localhost:5000/api/v1/health"
    case Req.get(url, receive_timeout: 1000) do
      {:ok, %{status: 200}} -> send_json(conn, 200, %{status: "ok", bridge: "connected"})
      _ -> send_json(conn, 503, %{status: "degraded", bridge: "unreachable"})
    end
  end

  get "/api/v1/visualization/city" do
    nodes = retrieve_city_nodes()
    
    send_json(conn, 200, %{
      timestamp: DateTime.utc_now(),
      nodes: nodes,
      district_count: Enum.count(nodes, & &1.type == "district"),
      building_count: Enum.count(nodes, & &1.type == "building")
    })
  end

  get "/dashboard" do
    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>CDMS Digital City Dashboard</title>
        <style>
            body { margin: 0; background: #050505; color: #00ffcc; font-family: 'Courier New', Courier, monospace; overflow: hidden; }
            #info { position: absolute; top: 10px; left: 10px; z-index: 100; pointer-events: none; background: rgba(0,0,0,0.7); padding: 10px; border: 1px solid #00ffcc; }
            #hud { position: absolute; bottom: 10px; right: 10px; z-index: 100; background: rgba(0,0,0,0.7); padding: 10px; border: 1px solid #00ffcc; max-width: 300px; display: none; }
            canvas { display: block; }
            .label { font-weight: bold; }
        </style>
    </head>
    <body>
        <div id="info">
            <h1>CDMS DIGITAL CITY</h1>
            <div id="stats">Anatomy: Loading... | Physiology: Linked</div>
        </div>
        <div id="hud">
            <h3>NODE IDENTITY</h3>
            <div id="node-name"></div>
            <div id="node-type"></div>
            <div id="node-pos"></div>
            <div id="node-links"></div>
        </div>

        <script type="importmap">
          {
            "imports": {
              "three": "https://unpkg.com/three@0.160.0/build/three.module.js",
              "three/addons/": "https://unpkg.com/three@0.160.0/examples/jsm/"
            }
          }
        </script>

        <script type="module">
            import * as THREE from 'three';
            import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

            let scene, camera, renderer, controls;
            let nodes = [];
            const raycaster = new THREE.Raycaster();
            const mouse = new THREE.Vector2();

            init();
            fetchData();
            animate();

            function init() {
                scene = new THREE.Scene();
                scene.fog = new THREE.FogExp2(0x050505, 0.002);

                camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 2000);
                camera.position.set(200, 150, 200);

                renderer = new THREE.WebGLRenderer({ antialias: true });
                renderer.setSize(window.innerWidth, window.innerHeight);
                renderer.setPixelRatio(window.devicePixelRatio);
                document.body.appendChild(renderer.domElement);

                controls = new OrbitControls(camera, renderer.domElement);
                controls.enableDamping = true;

                // Lights
                const ambientLight = new THREE.AmbientLight(0x404040, 2);
                scene.add(ambientLight);

                const directionalLight = new THREE.DirectionalLight(0x00ffcc, 1);
                directionalLight.position.set(1, 1, 1);
                scene.add(directionalLight);

                // Grid helper for the city floor
                const grid = new THREE.GridHelper(1000, 50, 0x00ffcc, 0x222222);
                scene.add(grid);

                window.addEventListener('resize', onWindowResize);
                window.addEventListener('mousemove', onMouseMove);
            }

            async function fetchData() {
                try {
                    const response = await fetch('/api/v1/visualization/city');
                    const data = await response.json();
                    renderCity(data.nodes);
                    document.getElementById('stats').innerText = `Districts: ${data.district_count} | Buildings: ${data.building_count}`;
                } catch (e) {
                    console.error("Failed to fetch city data", e);
                }
            }

            function renderCity(nodeData) {
                // Clear existing
                nodes.forEach(n => scene.remove(n.mesh));
                nodes = [];

                const buildingGeo = new THREE.BoxGeometry(1, 1, 1);
                const districtGeo = new THREE.BoxGeometry(20, 2, 20);

                nodeData.forEach(data => {
                    let material = new THREE.MeshPhongMaterial({ color: data.visuals.color, emissive: data.visuals.color, emissiveIntensity: 0.2 });
                    let mesh;

                    if (data.type === 'district') {
                        mesh = new THREE.Mesh(districtGeo, material);
                        mesh.position.set(data.position.x, 1, data.position.z);
                    } else {
                        mesh = new THREE.Mesh(buildingGeo, material);
                        mesh.scale.set(data.visuals.width * 5, data.visuals.height * 10, data.visuals.width * 5);
                        mesh.position.set(data.position.x, (data.visuals.height * 10) / 2, data.position.z);
                    }

                    mesh.userData = data;
                    scene.add(mesh);
                    nodes.push({ mesh, data });

                    // Render Links as lines (Arcs)
                    if (data.links && data.links.length > 0) {
                        data.links.forEach(link => {
                            const target = nodeData.find(n => n.node_id === link.target);
                            if (target) {
                                renderArc(data.position, target.position, data.visuals.color);
                            }
                        });
                    }
                });
            }

            function renderArc(start, end, color) {
                const points = [];
                const startVec = new THREE.Vector3(start.x, 5, start.z);
                const endVec = new THREE.Vector3(end.x, 5, end.z);
                
                // Curve height
                const dist = startVec.distanceTo(endVec);
                const mid = new THREE.Vector3().lerpVectors(startVec, endVec, 0.5);
                mid.y += dist * 0.2;

                const curve = new THREE.QuadraticBezierCurve3(startVec, mid, endVec);
                const curvePoints = curve.getPoints(20);
                
                const geometry = new THREE.BufferGeometry().setFromPoints(curvePoints);
                const material = new THREE.LineBasicMaterial({ color: color, transparent: true, opacity: 0.3 });
                const line = new THREE.Line(geometry, material);
                scene.add(line);
            }

            function onWindowResize() {
                camera.aspect = window.innerWidth / window.innerHeight;
                camera.updateProjectionMatrix();
                renderer.setSize(window.innerWidth, window.innerHeight);
            }

            function onMouseMove(event) {
                mouse.x = (event.clientX / window.innerWidth) * 2 - 1;
                mouse.y = -(event.clientY / window.innerHeight) * 2 + 1;

                raycaster.setFromCamera(mouse, camera);
                const intersects = raycaster.intersectObjects(nodes.map(n => n.mesh));

                if (intersects.length > 0) {
                    const node = intersects[0].object.userData;
                    const hud = document.getElementById('hud');
                    hud.style.display = 'block';
                    document.getElementById('node-name').innerText = "Name: " + node.name;
                    document.getElementById('node-type').innerText = "Type: " + node.type;
                    document.getElementById('node-pos').innerText = `Pos: [${node.position.x.toFixed(2)}, ${node.position.z.toFixed(2)}]`;
                    document.getElementById('node-links').innerText = "Links: " + (node.links ? node.links.length : 0);
                }
            }

            function animate() {
                requestAnimationFrame(animate);
                controls.update();
                renderer.render(scene, camera);
            }
        </script>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  # ----------------------------------------------------------------------------
  # 5. GENESIS API
  # ----------------------------------------------------------------------------
  post "/api/v1/genesis/start" do
    params = fetch_query_params(conn).params
    path = params["path"]
    
    expanded_path = if path, do: Path.expand(path), else: nil
    
    if expanded_path && File.dir?(expanded_path) do
      # Run in a separate process to avoid blocking the API response
      Task.start(fn -> 
        CMS.Services.GenesisCrawler.run(expanded_path)
      end)
      
      send_json(conn, 202, %{status: "accepted", message: "Genesis started", path: expanded_path})
    else
      Logger.error("Genesis API: Invalid path attempt -> #{inspect(expanded_path || path)}")
      send_json(conn, 400, %{
        error: "Invalid path", 
        provided: path,
        expanded: expanded_path,
        exists: if(expanded_path, do: File.dir?(expanded_path), else: false)
      })
    end
  end

  match _ do
    send_json(conn, 404, %{error: "Not Found"})
  end

  # --- Helpers ---
  # ----------------------------------------------------------------------------
  # PRIVATE HELPERS
  # ----------------------------------------------------------------------------
  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp validate_params(params, required_keys) do
    missing = Enum.filter(required_keys, fn k -> is_nil(params[k]) end)
    if Enum.empty?(missing), do: {:ok, params}, else: {:error, Enum.join(missing, ", ")}
  end

  defp parse_and_validate_payloads(list) when is_list(list) do
    results = Enum.map(list, fn item ->
      payload =
        case item["type"] do
          "text" -> %DataBodyPayload.Text{content: item["content"] || ""}
          "code" ->
            lang = safe_atom_cast(item["language"], :elixir, [:elixir, :python, :javascript, :json, :bash])
            %DataBodyPayload.Code{language: lang, content: item["content"] || ""}
          "number" ->
            unit = if item["unit"] && item["unit"] != "nil", do: safe_atom_cast(item["unit"], nil, [:meters, :seconds, :celsius, :count]), else: nil
            %DataBodyPayload.Number{value: item["value"], unit: unit}
          "link" -> %DataBodyPayload.Link{uri: item["uri"] || "", description: item["description"]}
          "object" ->
             type = safe_atom_cast(item["object_type"], :generic, [:sensor_data, :config, :metadata, :generic])
             %DataBodyPayload.Object{object_type: type, data: item["data"] || %{}}
          _ -> %DataBodyPayload.Text{content: "Unknown Payload"}
        end

      case FIDValidator.validate(payload) do
        :ok -> {:ok, payload}
        {:error, msg} -> {:error, msg}
      end
    end)

    error = Enum.find(results, fn {:error, _} -> true; _ -> false end)
    if error, do: {:error, {:validation, elem(error, 1)}}, else: {:ok, Enum.map(results, &elem(&1, 1))}
  end
  defp parse_and_validate_payloads(_), do: {:error, "Payloads must be a list"}

  defp parse_time_range(str) when is_binary(str) do
    # Parse formats like "60m", "2h", "1d"
    cond do
      String.ends_with?(str, "m") ->
        str |> String.trim_trailing("m") |> String.to_integer()
      
      String.ends_with?(str, "h") ->
        str |> String.trim_trailing("h") |> String.to_integer() |> Kernel.*(60)
      
      String.ends_with?(str, "d") ->
        str |> String.trim_trailing("d") |> String.to_integer() |> Kernel.*(1440)
      
      true ->
        # Assume minutes if no suffix
        String.to_integer(str)
    end
  rescue
    _ -> 60  # Default to 60 minutes
  end

  defp safe_atom_cast(str, default, allowlist) when is_binary(str) do
    try do
      atom = String.to_existing_atom(str)
      if atom in allowlist, do: atom, else: default
    rescue _ -> default end
  end
  defp safe_atom_cast(_, default, _), do: default

  # --- VISUALIZATION HELPERS ---

  defp retrieve_city_nodes do
    # Scan Mnesia for all nodes and their spatial meta
    :mnesia.dirty_all_keys(:nodes_table)
    |> Enum.map(fn uuid ->
      case :mnesia.dirty_read(:nodes_table, uuid) do
          [{_table, ^uuid, _hash, _parent, head, body, tail, _stack}] ->
          {x, y, z} = head.spatial_coords || {0.0, 0.0, 0}
          
          # Determine type: Directory = district, File = building
          # Fix: use mime_definition instead of mime_type
          mime = get_in(body, [:data_ledger, :mime_definition]) || "unknown"
          type = if mime == "inode/directory", do: "district", else: "building"
          
          # Color mapping
          color = case Path.extname(get_in(body, [:data_ledger, :physical_symlink]) || "") do
            ext when ext in [".ex", ".exs", ".py", ".js"] -> "#007bff" # Blue: Code
            ext when ext in [".json", ".yaml", ".conf", ".toml"] -> "#dc3545" # Red: Config
            _ -> "#6c757d" # Grey: Binary/Other
          end
          
          # Size (Height) mapping
          # Fix: CMS.DataTail doesn't have :size, we might need to derive it if possible
          # For now, use salience_score as a proxy or default to something visible
          height_factor = get_in(body, [:data_ledger, :salience_score]) || 0.5
          height = height_factor * 10.0
          
          # Extract semantic links for "arcs"
          links = Enum.map(tail.semantic, fn edge -> 
            %{target: edge.target_node_id, weight: edge.weight}
          end)

          %{
            node_id: uuid,
            position: %{x: x, y: y, z: z},
            type: type,
            visuals: %{
              color: color,
              height: height,
              width: 1.0
            },
            links: links,
            name: Path.basename(get_in(body, [:data_ledger, :physical_symlink]) || "unknown")
          }
        _ -> nil
      end
    end)
    |> Enum.filter(& &1 != nil)
  end
end

# ==============================================================================
# WEBSOCKET HANDLER
# ==============================================================================
defmodule CMS.Web.SocketHandler do
  @behaviour :cowboy_websocket
  require Logger

  @public_topics ["global:signals"]
  @admin_topics ["global:abnormality_signal", "system_congestion"]

  def init(req, state) do
    qs = :cowboy_req.parse_qs(req)
    token = :proplists.get_value("token", qs)
    permissions = if token == "admin_secret", do: :admin, else: :public
    {:cowboy_websocket, req, Map.put(state, :permissions, permissions)}
  end

  def websocket_init(state) do
    Enum.each(@public_topics, &Phoenix.PubSub.subscribe(CMS.PubSub, &1))
    if state[:permissions] == :admin, do: Enum.each(@admin_topics, &Phoenix.PubSub.subscribe(CMS.PubSub, &1))
    {:ok, state}
  end

  def websocket_handle({:text, json}, state) do
    {:reply, {:text, "ACK: " <> json}, state}
  end
  def websocket_handle(_frame, state), do: {:ok, state}

  def websocket_info(msg, state) do
    {:reply, {:text, serialize_event(msg)}, state}
  end

  defp serialize_event({:abnormality_signal, opts}) do
    Jason.encode!(%{event: "abnormality_signal", node_id: opts[:node_id], reason: opts[:reason], timestamp: DateTime.utc_now()})
  end
  defp serialize_event({:system_congestion, level}) do
    Jason.encode!(%{event: "system_congestion", level: level, timestamp: DateTime.utc_now()})
  end
  defp serialize_event(other), do: Jason.encode!(%{event: "signal", data: inspect(other)})

end
