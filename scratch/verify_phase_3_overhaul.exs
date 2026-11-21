# Phase 3 Overhaul Verification

path = Path.expand("scratch/test_controller.ex")
parent_id = "test-parent-uuid"

IO.puts("Ingesting Controller: #{path}")
{:ok, _status, uuid} = CMS.Ingestion.FileIngestionTask.ingest(path, parent_id, {0.0, 0.0, 0}, "m0", [cognitive_mode: :deterministic])

# Retrieve node
[{_, ^uuid, _hash, _parent, _head, body, _tail, _stack, _provenance, _antenna}] = :mnesia.dirty_read(:nodes_table, uuid)

IO.puts("\nExtracted Concepts:")
IO.inspect(body.data_head.concepts)

# Expectations
has_controller = "role:web_controller" in body.data_head.concepts
has_interface = "dimension:interface" in body.data_head.concepts

if has_controller and has_interface do
  IO.puts("\nSUCCESS: Phase 3 Overhaul Verified! Architectural roles detected via AST.")
else
  IO.puts("\nFAILED: Missing expected architectural concepts.")
  if not has_controller, do: IO.puts(" - Missing role:web_controller")
  if not has_interface, do: IO.puts(" - Missing dimension:interface")
  exit({:error, :verification_failed})
end
