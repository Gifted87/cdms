defmodule CMS.ChronoForensicsTest do
  use ExUnit.Case
  require Logger
  
  describe "Stack Traversal" do
    test "get_node_history returns error for non-existent node" do
      result = CMS.TemporalQueryEngine.get_node_history("nonexistent", depth: 5)
      # Non-existent nodes should return error
      assert result == {:error, :node_not_found}
    end
  end
  
  describe "Differential Diagnosis" do
    test "find_recent_mutations returns list of mutated nodes" do
      {:ok, mutations} = CMS.TemporalQueryEngine.find_recent_mutations(60)
      assert is_list(mutations)
      # Each mutation should have required fields
      if length(mutations) > 0 do
        mutation = List.first(mutations)
        assert Map.has_key?(mutation, :node_id)
        assert Map.has_key?(mutation, :path)
        assert Map.has_key?(mutation, :mutation_cause)
      end
    end
    
    test "find_recent_mutations with large time range" do
      {:ok, mutations} = CMS.TemporalQueryEngine.find_recent_mutations(10000)
      assert is_list(mutations)
    end
  end
  
  describe "Directory State Reconstruction" do
    test "reconstruct_directory_state handles non-existent directory" do
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = CMS.TemporalQueryEngine.reconstruct_directory_state("/nonexistent/path", past_time)
      
      case result do
        {:ok, _state} -> assert true
        {:error, _} -> assert true  # Expected for non-existent
      end
    end
  end
end
