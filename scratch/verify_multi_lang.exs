# Phase 3 & 4 Verification: Multi-lang & Concepts

path = Path.expand("scratch/test_python.py")
parent_id = "test-parent-uuid"

IO.puts("Ingesting Python file: #{path}")
{:ok, _status, uuid} = CMS.Ingestion.FileIngestionTask.ingest(path, parent_id, {0.0, 0.0, 0}, "m0", [cognitive_mode: :deterministic])

# Wait for edges/persistence
Process.sleep(1000)

# Retrieve node
[{_, ^uuid, _hash, _parent, _head, body, tail, _stack, _provenance, _antenna}] = :mnesia.dirty_read(:nodes_table, uuid)

IO.puts("\nNode Mode: #{body.mode}")
IO.puts("Summary Dimensions:")
IO.puts(body.data_head.summary)

IO.puts("\nExtracted Concepts:")
IO.inspect(body.data_head.concepts)

# Check Edges
IO.puts("\nFunctional Edges (Calls/Defines):")
IO.inspect(tail.functional)

IO.puts("\nSyntactic Edges (Imports):")
IO.inspect(tail.syntactic)

# Expectations
has_python_concept = "lang:python" in body.data_head.concepts
has_matrix_processor = Enum.any?(tail.functional, fn e -> e.type == :defines end)
has_math_import = Enum.any?(tail.syntactic, fn e -> e.type == :imports end)

if has_python_concept and has_matrix_processor and has_math_import do
  IO.puts("\nSUCCESS: Multi-lang Deterministic Mode Verified!")
else
  IO.puts("\nFAILED: Missing expected data.")
  if not has_python_concept, do: IO.puts(" - Missing lang:python concept")
  if not has_matrix_processor, do: IO.puts(" - Missing MatrixProcessor definition edge")
  if not has_math_import, do: IO.puts(" - Missing math import edge")
  exit({:error, :verification_failed})
end
