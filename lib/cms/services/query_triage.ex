defmodule CMS.QueryTriage do
  @moduledoc """
  The Query Router Triage Logic
  
  Analyzes input query strings and routes them to the appropriate mode:
  - Mode A (Symbolic): Path detection → O(1) path lookup
  - Mode B (Nominal): Filename detection → Name-based search with disambiguation
  - Mode C (Semantic): Natural language → Vector search
  """

  require Logger

  @doc """
  Routes a query string to the appropriate mode.
  
  Returns: `{:symbolic, path}` | `{:nominal, filename}` | `{:semantic, text}`
  """
  def route(query_string, opts \\ [])
  
  def route(query_string, opts) when is_binary(query_string) do
    # Allow manual override
    case Keyword.get(opts, :mode) do
      mode when mode in [:symbolic, :nominal, :semantic] ->
        {mode, query_string}
      _ ->
        auto_route(query_string)
    end
  end

  defp auto_route(query_string) do
    cond do
      # Gate 1: Symbolic Check (Path Detection)
      is_path?(query_string) ->
        {:symbolic, expand_path(query_string)}

      # Gate 2: Nominal Check (Filename Detection)
      is_filename?(query_string) ->
        {:nominal, query_string}

      # Gate 3: Semantic Check (Natural Language)
      true ->
        {:semantic, query_string}
    end
  end

  # --- GATE 1: Path Detection ---
  
  defp is_path?(str) do
    # Heuristics:
    # - Starts with root indicator: /, ~/, C:\
    # - Contains path separators
    # - Starts with ./ or ../
    Regex.match?(~r{^(/|~/|[A-Z]:\\|\\./|\\.\\./)}i, str) or 
    String.contains?(str, "/") and not has_nl_indicators?(str)
  end

  defp expand_path(path) do
    # Expand ~ and relative paths
    Path.expand(path)
  end

  # --- GATE 2: Filename Detection ---
  
  defp is_filename?(str) do
    # Heuristics:
    # - Single token (no spaces or only one space)
    # - Has file extension
    # - No natural language indicators
    is_single_token?(str) and
    has_file_extension?(str) and
    not has_nl_indicators?(str)
  end

  defp is_single_token?(str) do
    # Allow one space for "config json" but not multiple
    parts = String.split(str, " ", trim: true)
    length(parts) <= 2
  end

  defp has_file_extension?(str) do
    ext = Path.extname(str)
    ext != "" and String.length(ext) <= 6  # Reasonable extension length
  end

  # --- GATE 3: Natural Language Detection ---
  
  defp has_nl_indicators?(str) do
    # Indicators of natural language:
    # - Contains question marks
    # - Contains multiple spaces
    # - Contains common verbs/articles
    String.contains?(str, "?") or
    String.contains?(str, "!") or
    length(String.split(str, " ", trim: true)) >= 4 or
    has_common_words?(str)
  end

  defp has_common_words?(str) do
    lower = String.downcase(str)
    
    # Common English words that indicate natural language
    indicators = [
      "how", "what", "why", "when", "where", "who",
      "is", "are", "was", "were", "the", "a", "an",
      "does", "do", "can", "should", "would"
    ]
    
    Enum.any?(indicators, fn word -> String.contains?(lower, " #{word} ") or String.starts_with?(lower, "#{word} ") end)
  end

  @doc """
  Executes an optimized query based on the detected mode.
  
  Returns standardized result format:
  `{:ok, mode, results}` | `{:error, reason}`
  """
  def execute(query_string, opts \\ []) do
    {mode, processed_query} = route(query_string, opts)
    Logger.debug("QueryTriage: Detected mode=#{mode} for query: #{String.slice(query_string, 0, 50)}")
    
    case mode do
      :symbolic ->
        execute_symbolic(processed_query, opts)
      
      :nominal ->
        execute_nominal(processed_query, opts)
      
      :semantic ->
        execute_semantic(processed_query, opts)
    end
  end

  # --- Mode A: Symbolic Execution ---
  
  defp execute_symbolic(path, _opts) do
    case CMS.SymbolicIndex.get_node_by_path(path) do
      {:ok, pid} ->
        case GenServer.call(pid, :get_state_snapshot, 5000) do
          {:ok, node} -> {:ok, :symbolic, [node]}
          node when is_map(node) -> {:ok, :symbolic, [node]}
          _ -> {:error, :node_unreachable}
        end
      {:error, :not_found} ->
        {:ok, :symbolic, []}
    end
  rescue
    _ -> {:error, :lookup_failed}
  end

  # --- Mode B: Nominal Execution ---
  
  defp execute_nominal(filename, _opts) do
    case CMS.VectorRouter.find_by_name(filename) do
      {:ok, uuid} ->
        # Single match - return it
        case fetch_node(uuid) do
          {:ok, node} ->
            # Add disambiguation context
            parent_path = get_parent_path(node)
            result = Map.put(node, :context, parent_path)
            {:ok, :nominal, [result]}
          _ ->
            {:ok, :nominal, []}
        end
      
      {:error, :not_found} ->
        # Try to find all matches (future enhancement)
        {:ok, :nominal, []}
    end
  end

  defp fetch_node(uuid) do
    case CMS.NodeSupervisor.get_node_pid(uuid) do
      nil -> {:error, :not_found}
      pid ->
        try do
          case GenServer.call(pid, :get_state_snapshot, 5000) do
            {:ok, node} -> {:ok, node}
            node when is_map(node) -> {:ok, node}
            _ -> {:error, :invalid_response}
          end
        catch
          _, _ -> {:error, :call_failed}
        end
    end
  end

  defp get_parent_path(node) do
    # Extract parent path from node for disambiguation
    # Use direct struct access instead of get_in/2 since CMS.Node doesn't implement Access
    path = case node do
      %CMS.Node{body: %{data_ledger: %{physical_symlink: symlink}}} when is_binary(symlink) ->
        symlink
      %{body: %{data_ledger: %{physical_symlink: symlink}}} when is_binary(symlink) ->
        symlink
      _ ->
        "unknown"
    end
    
    if path != "unknown" do
      Path.dirname(path)
    else
      "unknown"
    end
  end

  # --- Mode C: Semantic Execution ---
  
  defp execute_semantic(text, opts) do
    # Delegate to decentralized search
    model = Keyword.get(opts, :model, "all-MiniLM-L6-v2")
    
    case CMS.Tool.Embedder.generate(text, model) do
      {:ok, vector} ->
        query_id = UUID.uuid4()
        
        # Prepare Query Context
        query_context = %{
          query_id: query_id,
          query_vector: vector,
          query_text: text,
          agent_id: "anonymous", # Default for triage
          trace: MapSet.new(),
          embedding_model: model,
          min_relevance: Keyword.get(opts, :threshold, 0.35),
          reasoning_mode: :normal,
          system_mode: :normal
        }

        # Start a coordinator to collect decentralized responses
        # We need a way to receive the results synchronously here for the TRIAGE execute/2 call
        # We'll use the same pattern as CMS.Web.Router (waiting for ready signal and results)
        
        target_regions = [CMS.SemanticRegion.compute_region_hash(vector, model)]
        
        coord_opts = [max_results: Keyword.get(opts, :max_results)]
        {:ok, coord_pid} = CMS.QueryCoordinator.start_link(query_id, target_regions, self(), coord_opts)
        ref = Process.monitor(coord_pid)

        receive do
          {:coordinator_ready, ^query_id} ->
            Logger.debug("QueryTriage: Coordinator #{query_id} confirmed ready. Dispatching decentralized broadcast.")
            CMS.BroadcastCoordinator.broadcast_query(query_context)
          {:DOWN, ^ref, :process, _pid, _reason} ->
            :ok
        after
          2000 -> Logger.error("QueryTriage: Timeout waiting for coordinator ready signal.")
        end

        # Wait for results
        results =
          receive do
            {:query_result, ^query_id, received_results} ->
              Process.demonitor(ref, [:flush])
              # Standardize format: results are {score, node} tuples from coordinator
              Enum.map(received_results, fn {score, node} -> %{node: node, score: score} end)
            {:DOWN, ^ref, :process, _pid, _reason} ->
              []
          after 10000 ->
            Process.demonitor(ref, [:flush])
            []
          end

        {:ok, :semantic, results}
      
      {:error, _} ->
        {:error, :embedding_failed}
    end
  end
end
