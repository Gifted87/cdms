# verify_phase_1.exs
Application.put_env(:acn_cms, :node_base_threshold, 0.4)
Application.put_env(:acn_cms, :incremental_binding, true)

# Ensure CDMS is running (mix run already starts it)
# case CMS.Application.start(:normal, []) do
#   {:ok, _} -> :ok
#   {:error, {:already_started, _}} -> :ok
# end

parent_id = "test-parent-uuid"

path_dep = Path.expand("lib/cms/ingestion/anatomy_engine.ex")
IO.puts("Ingesting dependency #{path_dep}...")
{:ok, _status_dep, _uuid_dep} = CMS.Ingestion.FileIngestionTask.ingest(path_dep, parent_id, {0.0, 0.0, 0}, "m0", [cognitive_mode: :deterministic])

path = Path.expand("lib/cms/ingestion/deterministic_aggregator.ex")
# We use a unique parent ID for this test

IO.puts("Ingesting #{path} in deterministic mode...")
{:ok, status, uuid} = CMS.Ingestion.FileIngestionTask.ingest(path, parent_id, {0.0, 0.0, 0}, "m0", [cognitive_mode: :deterministic])
IO.puts("Ingestion status: #{status}")

# Wait for the actor to be registered and forge edges
Process.sleep(1000)

case CMS.NodeSupervisor.get_node_pid(uuid) do
  nil ->
    IO.puts("FAILED: Node actor not found for #{uuid}")
    exit({:error, :not_found})
  pid ->
    {:ok, node} = GenServer.call(pid, :get_state_snapshot)
    IO.puts("Node Mode: #{node.body.mode}")
    IO.puts("Syntactic Edges: #{inspect(node.tail.syntactic)}")
    
    has_imports = Enum.any?(node.tail.syntactic, fn e -> e.type == :imports end)
    
    if node.body.mode == :deterministic and has_imports do
      IO.puts("SUCCESS: Deterministic node has syntactic edges!")
    else
      IO.puts("FAILED: Expected deterministic mode and syntactic edges.")
      IO.puts("Actual Mode: #{node.body.mode}")
      IO.puts("Edge count: #{length(node.tail.syntactic)}")
      exit({:error, :verification_failed})
    end
end
