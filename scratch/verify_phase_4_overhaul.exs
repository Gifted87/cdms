# Phase 4 Overhaul Verification

path = Path.expand("scratch/test_hierarchy.py")
parent_id = "test-parent-uuid"

IO.puts("Ingesting Hierarchical Python: #{path}")
{:ok, _status, uuid} = CMS.Ingestion.FileIngestionTask.ingest(path, parent_id, {0.0, 0.0, 0}, "m0", [cognitive_mode: :deterministic])

# Retrieve node
[{_, ^uuid, _hash, _parent, _head, body, tail, _stack, _provenance, _antenna}] = :mnesia.dirty_read(:nodes_table, uuid)

IO.puts("\nFunctional Edges (Defines):")
defines = Enum.filter(tail.functional, fn e -> e.type == :defines end)
Enum.each(defines, fn e -> 
  # Since IDs are opaque, let's just check the summary which contains the defines text
  IO.puts("Edge found.")
end)

# Better check: Look at the Summary dimension
IO.puts("\nSummary Structure:")
IO.puts(body.data_head.summary |> String.split("[STRUCTURE]: ") |> List.last() |> String.split("\n") |> List.first())

# Expectations
summary = body.data_head.summary
has_nested = String.contains?(summary, "MatrixProcessor.process")
has_deep_nested = String.contains?(summary, "MatrixProcessor.process.local_helper")

if has_nested and has_deep_nested do
  IO.puts("\nSUCCESS: Phase 4 Overhaul Verified! Hierarchical namespacing detected.")
else
  IO.puts("\nFAILED: Missing hierarchical definitions.")
  if not has_nested, do: IO.puts(" - Missing MatrixProcessor.process")
  if not has_deep_nested, do: IO.puts(" - Missing MatrixProcessor.process.local_helper")
  exit({:error, :verification_failed})
end
