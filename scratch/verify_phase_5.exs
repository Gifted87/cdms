# Phase 5 Verification: Ghost Resolution

parent_id = "test-parent-uuid"

IO.puts("1. Ingesting A.py (Imports B which doesn't exist yet)")
{:ok, _, id_a} = CMS.Ingestion.FileIngestionTask.ingest("scratch/A.py", parent_id, {0.0,0.0,0}, "m0", [cognitive_mode: :deterministic])

Process.sleep(500)
[{_, ^id_a, _, _, _, _, tail_a, _, _, _}] = :mnesia.dirty_read(:nodes_table, id_a)
ghost_id = Enum.find(tail_a.syntactic, fn e -> e.type == :imports end).target_node_id

[{_, ^ghost_id, _, _, head_g, _, _, _, _, _}] = :mnesia.dirty_read(:nodes_table, ghost_id)
IO.puts("Detected Ghost Node ID: #{ghost_id} (Width: #{head_g.width_descriptor})")

IO.puts("\n2. Ingesting B.py (Defines B)")
{:ok, _, id_b} = CMS.Ingestion.FileIngestionTask.ingest("scratch/B.py", parent_id, {0.1,0.1,0}, "m0", [cognitive_mode: :deterministic])
Process.sleep(500)

IO.puts("\n3. Running PostGenesisBinder Resolution Pass...")
CMS.Ingestion.PostGenesisBinder.run_pass()

IO.puts("\n4. Verifying Resolution...")
[{_, ^id_a, _, _, _, _, tail_a_new, _, _, _}] = :mnesia.dirty_read(:nodes_table, id_a)
resolved_id = Enum.find(tail_a_new.syntactic, fn e -> e.type == :imports end).target_node_id

if resolved_id == id_b do
  IO.puts("SUCCESS: Ghost Node resolved to Real Node ID: #{id_b}")
  
  # Check if ghost is deleted
  case :mnesia.dirty_read(:nodes_table, ghost_id) do
    [] -> IO.puts("SUCCESS: Ghost Node correctly purged from database.")
    _ -> IO.puts("WARNING: Ghost Node still exists in database.")
  end
else
  IO.puts("FAILED: Edge still points to Ghost or wrong node. Expected #{id_b}, got #{resolved_id}")
  exit({:error, :resolution_failed})
end
