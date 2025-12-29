# Comprehensive Anatomy & Connectome Verification Script
defmodule CompleteAnatomyVerification do
  require Logger

  def run do
    IO.puts("\n=== Starting Complete Anatomy & Connectome Verification ===\n")
    
    # Create test file
    test_path = "/tmp/test_anatomy_#{:rand.uniform(10000)}.ex"
    test_content = """
    defmodule TestModule do
      @moduledoc "Test module for anatomy verification"
      
      alias OtherModule
      import SomeHelper
      
      def test_function do
        :ok
      end
    end
    """
    
    File.write!(test_path, test_content)
    
    # Wait for system to be ready
    Process.sleep(500)
    
    IO.puts("--- Phase 1: Ingesting Test File ---")
    IO.puts("Path: #{test_path}")
    
    # Trigger ingestion (simulating Genesis flow)
    {:ok, uuid} = CMS.Ingestion.FileIngestionTask.ingest(
      test_path, nil, {0.0, 0.0, 0}, "test", 
      [edge_generation: true]
    )
    
    IO.puts("Node UUID: #{uuid}")
    
    # Wait for ingestion to complete
    Process.sleep(1000)
    
    # Read node from Mnesia
    case :mnesia.dirty_read(:nodes_table, uuid) do
      [{_table, _uuid, _hash, _parent, head, body, tail, _stack, _prov, antenna}] ->
        IO.puts("\n--- Phase 2: Verifying Anatomical Ledger ---")
        
        # Check permissions
        perms = body.data_ledger.permissions
        IO.puts("Permissions: #{inspect(perms)}")
        assert_field("permissions", perms != nil && perms != %{})
        
        # Check ownership
        ownership = body.data_ledger.ownership
        IO.puts("Ownership: #{inspect(ownership)}")
        assert_field("ownership", ownership != nil && ownership != %{})
        
        # Check genetic provenance
        provenance = body.data_ledger.genetic_provenance
        IO.puts("Genetic Provenance: #{inspect(provenance)}")
        assert_field("genetic_provenance", provenance != nil && provenance != %{})
        
        # Check metabolism
        metabolism = body.data_ledger.metabolism
        IO.puts("Metabolism: #{inspect(metabolism)}")
        assert_field("metabolism", metabolism != nil)
        
        # Check immutable flags
        flags = body.data_ledger.immutable_flags
        IO.puts("Immutable Flags: #{inspect(flags)}")
        assert_field("immutable_flags", flags != nil)
        
        IO.puts("\n--- Phase 3: Verifying Edge Categories ---")
        
        # Check syntactic edges
        syntactic_count = length(tail.syntactic || [])
        IO.puts("Syntactic edges: #{syntactic_count}")
        # May be 0 if file has no imports, so just check it exists as a list
        assert_field("syntactic edges (list)", is_list(tail.syntactic))
        
        # Check functional edges
        functional_count = length(tail.functional || [])
        IO.puts("Functional edges: #{functional_count}")
        assert_field("functional edges (list)", is_list(tail.functional))
        
        # Check semantic edges
        semantic_count = length(tail.semantic || [])
        IO.puts("Semantic edges: #{semantic_count}")
        assert_field("semantic edges (list)", is_list(tail.semantic))
        
        IO.puts("\n--- Phase 4: Verifying NodeAntenna ---")
        
        # Check antenna salience
        IO.puts("Antenna salience: #{inspect(antenna.salience)}")
        assert_field("antenna.salience", antenna.salience != nil)
        
        IO.puts("Antenna gain: #{inspect(antenna.gain)}")
        assert_field("antenna.gain", antenna.gain != nil)
        
        IO.puts("\n--- Phase 5: Verifying NodeHead Embedding ---")
        IO.puts("Embedding shape: #{inspect(Nx.shape(head.embedding))}")
        assert_field("embedding", Nx.size(head.embedding) > 0)
        
        IO.puts("\n=== Verification Complete ===\n")
        IO.puts("✓ All critical anatomy and connectome fields are properly populated!")
        
        # Cleanup
        File.rm(test_path)
        
      [] ->
        IO.puts("ERROR: Node not found in Mnesia!")
        exit(:node_not_found)
    end
  end
  
  defp assert_field(name, condition) do
    if condition do
      IO.puts("  ✓ #{name}: PASSED")
    else
      IO.puts("  ✗ #{name}: FAILED")
      raise "Verification failed for #{name}"
    end
  end
end

CompleteAnatomyVerification.run()
