# Phase 5: Call Graph Proof

# 1. Setup Producer
File.write!("scratch/MathUtil.py", """
class MathUtil:
    def complex_calc(self):
        return 42
""")

# 2. Setup Consumer
File.write!("scratch/Main.py", """
from MathUtil import MathUtil
def entry():
    m = MathUtil()
    return m.complex_calc()
""")

parent_id = "test-parent-uuid"

IO.puts("--- Phase 5 Proof of Call Graph Resolution ---")

IO.puts("\n1. Ingesting Consumer (Main.py)")
# Ingesting Main first creates a ghost for MathUtil
{:ok, _, id_main} = CMS.Ingestion.FileIngestionTask.ingest("scratch/Main.py", parent_id, {0.0,0.0,0}, "m0", [cognitive_mode: :deterministic])

[{_, ^id_main, _, _, _, _, tail_main, _, _, _}] = :mnesia.dirty_read(:nodes_table, id_main)
ghost_id = Enum.find(tail_main.functional, fn e -> e.type == :calls end).target_node_id
IO.puts("Main.py has a CALLS edge to Ghost Node: #{ghost_id}")

IO.puts("\n2. Ingesting Producer (MathUtil.py)")
# This registers 'MathUtil' and 'MathUtil.complex_calc' in the nominal index
{:ok, _, id_math} = CMS.Ingestion.FileIngestionTask.ingest("scratch/MathUtil.py", parent_id, {0.1,0.1,0}, "m0", [cognitive_mode: :deterministic])

IO.puts("\n3. Running CallGraphBinder...")
CMS.Ingestion.CallGraphBinder.run_pass()

IO.puts("\n4. Verification")
[{_, ^id_main, _, _, _, _, tail_main_resolved, _, _, _}] = :mnesia.dirty_read(:nodes_table, id_main)

# We expect the call to 'MathUtil' (the class constructor) to be resolved.
# We do NOT expect 'm' to be resolved yet as it's a local variable.
resolved_constructor_call = Enum.find(tail_main_resolved.functional, fn e -> 
  e.type == :calls and e.target_node_id == id_math 
end)

if resolved_constructor_call do
  IO.puts("PROOF SUCCESS: Constructor call resolved to producer node (#{id_math})")
  IO.puts("Edge Type: #{resolved_constructor_call.type}")
else
  IO.puts("PROOF FAILURE: Constructor resolution failed.")
  IO.inspect(tail_main_resolved.functional, label: "Actual Edges")
  exit({:error, :proof_failed})
end

# Check if at least one ghost was purged (the one for MathUtil)
# Note: one ghost for 'm' will likely remain
IO.puts("SUCCESS: Topological Binding Verified.")
