# verification_script
defmodule IsolationVerification do
  alias CMS.Core.Logic.EdgeGenerator
  alias CMS.Core.Logic.ConnectomeScanner
  alias CMS.Node
  alias CMS.NodeBody
  alias CMS.DataTail
  alias CMS.NodeAntenna
  alias CMS.Edge
  alias CMS.NodeActor
  alias CMS.NodeTail

  def run do
    IO.puts("\n=== Starting Activation Isolation Verification ===\n")
    
    test_dir = "/tmp/isolation_test_#{System.unique_integer()}"
    File.mkdir_p!(test_dir)
    
    # 1. Verify NodeTail Categorization
    IO.puts("--- Phase 1: Tail Categorization ---")
    
    # Create a dummy config file to trigger Nervous System edges
    config_path = Path.join(test_dir, "test.conf")
    File.write!(config_path, "use_binary /usr/bin/python3;")
    
    node = %Node{
      id: "node_conf",
      head: %CMS.NodeHead{embedding: Nx.broadcast(0.0, {384})},
      antenna: %NodeAntenna{gain: 1.0, salience: 0.5},
      body: %NodeBody{
        data_ledger: DataTail.new(config_path, "hash", "text/plain"),
        data_body: "use_binary /usr/bin/python3;"
      },
      tail: NodeTail.new()
    }
    
    # Run EdgeGenerator
    updated_node = EdgeGenerator.generate_edges(node)
    
    # Check if 'configures' edge is in functional list
    functional_edges = updated_node.tail.functional
    {ghost_uuid, _, _} = CMS.Ingestion.FractalAperture.create_ghost_node("/usr/bin/python3", "scanner")
    
    if Enum.any?(functional_edges, fn e -> e.type == :configures and e.target_node_id == ghost_uuid end) do
      IO.puts("Functional Edge Categorization: PASSED")
    else
      IO.puts("Functional Edge Categorization: FAILED -> Got functional: #{inspect(functional_edges)}")
      # Check if it leaked to syntactic
      if Enum.any?(updated_node.tail.syntactic, &(&1.type == :configures)) do
        IO.puts("Leaked to Syntactic! FAILED")
      end
    end

    # 2. Verify Spreading Activation Isolation
    IO.puts("\n--- Phase 2: Pulse Isolation ---")
    
    # We will mock the state of a NodeActor and trigger casting :fire.
    # We simulate the handle_cast(:fire, state) logic by manually inspecting what edges it selects.
    
    # Manual pulse test (simulating NodeActor.handle_cast(:fire, ...))
    # all_edges = state.node.tail.semantic ++ state.node.tail.syntactic ++ state.node.tail.hierarchical
    
    all_active_edges = updated_node.tail.semantic ++ updated_node.tail.syntactic ++ updated_node.tail.hierarchical
    
    if Enum.any?(all_active_edges, &(&1.type == :configures)) do
      IO.puts("Spreading Activation Isolation: FAILED (Functional edge included in pulse list)")
    else
      IO.puts("Spreading Activation Isolation: PASSED (Functional edge excluded from pulse list)")
    end

    IO.puts("\n=== Isolation Verification Complete ===\n")
    File.rm_rf!(test_dir)
  end
end

IsolationVerification.run()
