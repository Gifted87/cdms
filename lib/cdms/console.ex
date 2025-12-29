defmodule CDMS.Console do
  @moduledoc """
  Utilities for interacting with CDMS from the IEx console.
  """
  require Logger

  @doc "Ingests a single file and returns the node ID."
  def ingest_file(path) do
    case CMS.Ingestion.FileIngestionTask.ingest(Path.expand(path), nil, {0.0, 0.0, 0}, "m0", [edge_generation: true]) do
      {:ok, uuid} -> 
        IO.puts("✓ Ingested: #{uuid}")
        uuid
      error -> 
        IO.puts("✗ Error: #{inspect(error)}")
        error
    end
  end

  @doc "Performs a full multi-pass Genesis (Cold Boot) on a directory."
  def genesis(path) do
    CMS.Services.GenesisCrawler.run(path)
  end

  @doc "Inspects a node's anatomy and edges by UUID."
  def inspect_node(uuid) do
    case :mnesia.dirty_read(:nodes_table, uuid) do
      [{_, _, _, _, _head, body, tail, _, _, antenna}] ->
        %{
          summary: body.data_head.summary,
          anatomy: %{
            perms: body.data_ledger.permissions,
            owner: body.data_ledger.ownership,
            meta: body.data_ledger.metabolism,
            salience: body.data_ledger.salience_score
          },
          edges: %{
            semantic: length(tail.semantic),
            syntactic: length(tail.syntactic),
            functional: length(tail.functional)
          },
          antenna: %{
            gain: antenna.gain,
            salience: antenna.salience
          }
        } |> IO.inspect(label: "Node Details [#{uuid}]")
      [] -> 
        IO.puts("✗ Node #{uuid} not found")
        :not_found
    end
  end
  
  @doc "Lists last 10 nodes summary"
  def list_nodes(limit \\ 10) do
    :mnesia.dirty_match_object({:nodes_table, :_, :_, :_, :_, :_, :_, :_, :_, :_})
    |> Enum.take(limit)
    |> Enum.map(fn {_, uuid, _, _, _, body, _, _, _, _} -> 
      {uuid, body.data_ledger.physical_symlink}
    end)
    |> IO.inspect(label: "Recent Nodes")
  end

  @doc "Performs a unified query (Symbolic, Nominal, or Semantic) with triage."
  def unified_query(query_string) do
    CMS.QueryTriage.execute(query_string)
    |> IO.inspect(label: "Unified Query Results")
  end

  @doc "Performs a direct semantic search."
  def semantic_query(text, limit \\ 10) do
    case CMS.Tool.Embedder.generate(text, "all-MiniLM-L6-v2") do
      {:ok, vector} ->
        case CMS.VectorRouter.query(vector, "all-MiniLM-L6-v2", k: limit) do
          {:ok, results} -> 
            results |> IO.inspect(label: "Semantic Results")
          err -> err
        end
      err -> err
    end
  end

  @doc "Retrieves a node's state at a specific point in time."
  def temporal_query(uuid, iso_timestamp) do
    case DateTime.from_iso8601(iso_timestamp) do
      {:ok, dt, _} ->
        CMS.TemporalQueryEngine.get_node_state_at_time(uuid, dt)
        |> IO.inspect(label: "Temporal State [#{uuid} @ #{iso_timestamp}]")
      err -> err
    end
  end

  @doc "Lists recent mutations in the last N minutes."
  def list_mutations(minutes \\ 60) do
    CMS.TemporalQueryEngine.find_recent_mutations(minutes)
    |> IO.inspect(label: "Recent Mutations (Last #{minutes}m)")
  end
end
