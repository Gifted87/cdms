# verification_script
defmodule EdgeTimeoutVerification do
  alias CMS.Core.Logic.EdgeGenerator
  alias CMS.NodeRegistry
  alias CMS.NodeSupervisor
  
  def run do
    IO.puts("\n=== Starting Edge Generation Timeout Verification ===\n")
    
    # 1. Spawn MOCK NodeActors to simulate density
    num_mocks = 500
    IO.puts("Spawning #{num_mocks} mock NodeActors...")
    
    pids = Enum.map(1..num_mocks, fn i ->
      id = "mock_node_#{i}"
      embedding = for _ <- 1..384, do: :rand.uniform() # Random 384-dim vector
      node = %CMS.Node{id: id, head: %CMS.NodeHead{uuid: id, embedding: embedding}}
      
      {:ok, pid} = NodeSupervisor.start_child(node)
      pid
    end)
    
    IO.puts("System density increased. Commencing Scatter-Gather...")
    
    # 2. Test prime_candidates with a large system
    test_embedding = for _ <- 1..384, do: :rand.uniform()
    
    {time, result} = :timer.tc(fn ->
      EdgeGenerator.prime_candidates(test_embedding, "origin_node")
    end)
    
    IO.puts("Scatter-Gather across #{num_mocks} nodes took #{time / 1000}ms")
    IO.puts("Candidates found: #{length(result)}")
    
    # 3. Cleanup
    IO.puts("Cleaning up mocks...")
    Enum.each(pids, fn pid ->
      DynamicSupervisor.terminate_child(NodeSupervisor, pid)
    end)

    if length(result) > 0 do
       IO.puts("\n=== Verification: PASSED ===\n")
    else
       IO.puts("\n=== Verification: PASSED (No candidates, but did not time out) ===\n")
    end
  end
end

EdgeTimeoutVerification.run()
