# Startup CDMS and trigger Genesis
# Then check for hardware nodes

IO.puts("Starting Genesis...")
CREMS.Ingestion.RuntimeSwarm.start_genesis()

# Give it a few seconds to scan and embed
Process.sleep(5000)

IO.puts("\n--- Node Registry Check ---")
hw_nodes = ["hw:cpu", "hw:ram", "hw:storage:/"]

Enum.each(hw_nodes, fn id ->
  case Registry.lookup(CMS.NodeRegistry, id) do
    [{pid, _}] -> 
      IO.puts("Found #{id} at #{inspect(pid)}")
      {:ok, state} = GenServer.call(pid, :get_state_snapshot)
      IO.puts("  Fact: #{state.body.natural_language_fact}")
      IO.puts("  Feelings: #{state.body.fid_effect}")
      IO.puts("  Stress: #{state.body.fid_stress}")
      IO.puts("  Strain: #{state.body.fid_strain}")
    [] -> 
      IO.puts("MISSING: #{id}")
  end
end)
