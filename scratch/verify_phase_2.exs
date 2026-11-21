# Phase 2 Verification Script: Codegraph NIF Integration

parent_id = "test-parent-uuid"

# 1. Ingest AnatomyEngine first (so its name is registered)
path_dep = Path.expand("lib/cms/ingestion/anatomy_engine.ex")
IO.puts("Ingesting dependency #{path_dep}...")
{:ok, _status_dep, _uuid_dep} = CMS.Ingestion.FileIngestionTask.ingest(path_dep, parent_id, {0.0, 0.0, 0}, "m0", [cognitive_mode: :deterministic])

# 2. Ingest DeterministicAggregator
path = Path.expand("lib/cms/ingestion/deterministic_aggregator.ex")
IO.puts("Ingesting #{path} in deterministic mode...")
{:ok, _status, uuid} = CMS.Ingestion.FileIngestionTask.ingest(path, parent_id, {0.0, 0.0, 0}, "m0", [cognitive_mode: :deterministic])

# Wait for edges
Process.sleep(1000)

# 3. Retrieve node and check edges
[{_, ^uuid, _hash, _parent, _head, body, tail, _stack, _provenance, _antenna}] = :mnesia.dirty_read(:nodes_table, uuid)

IO.puts("\nNode Mode: #{body.mode}")

# Check functional edges (which include :calls and :defines)
functional_edges = tail.functional
IO.puts("Functional Edges: #{inspect(functional_edges)}")

# Check syntactic edges (which include :imports)
syntactic_edges = tail.syntactic
IO.puts("Syntactic Edges: #{inspect(syntactic_edges)}")

# We expect at least one :calls edge to AnatomyEngine
has_calls = Enum.any?(functional_edges, fn e -> e.type == :calls end)
has_imports = Enum.any?(syntactic_edges, fn e -> e.type == :imports end)

if has_calls and has_imports do
  IO.puts("\nSUCCESS: Phase 2 verified! AST-based edges (:calls and :imports) detected.")
else
  IO.puts("\nFAILED: Missing expected edges.")
  if not has_calls, do: IO.puts(" - Missing :calls edges")
  if not has_imports, do: IO.puts(" - Missing :imports edges")
  exit({:error, :verification_failed})
end
