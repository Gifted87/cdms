defmodule CMS.Phase1Test do
  use ExUnit.Case
  require Logger
  alias CMS.NodeSupervisor

  @tag :phase1
  test "Phase 1: Full Ingestion Simulation" do
    # 1. Setup Dummy Directory
    tmp_dir = Path.join(System.tmp_dir!(), "cdms_test_project_#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule Test do end") # Config (High Gain)
    File.write!(Path.join(tmp_dir, "lib.ex"), "defmodule Lib do end") # Source (High Gain)
    File.write!(Path.join(tmp_dir, "readme.txt"), "Documentation") # Doc (Medium Gain)
    File.write!(Path.join(tmp_dir, "temp.log"), "Log file") # Log (Low Gain)

    # 2. Launch Genesis
    # We use start_directory_agent directly to avoid "app.start" issues in test environment
    {:ok, _pid} = NodeSupervisor.start_directory_agent(tmp_dir, nil)

    # 3. Wait for Ingestion (Active Wait)
    # 4 files + 1 dir = 5 nodes.
    wait_for_nodes(5, 10_000)
    
    # 4. Verification
    all_pids = NodeSupervisor.get_all_active_node_pids()
    assert length(all_pids) >= 5
    
    # Check specific node attributes
    nodes = Enum.map(all_pids, fn pid -> 
       {:ok, node} = GenServer.call(pid, :get_state_snapshot)
       node
    end)
    
    # Verify Antenna Gains
    config_node = Enum.find(nodes, fn n -> String.contains?(n.body.data_ledger.physical_symlink, "mix.exs") end)
    assert config_node.antenna.gain == 0.8
    
    log_node = Enum.find(nodes, fn n -> String.contains?(n.body.data_ledger.physical_symlink, "temp.log") end)
    assert log_node.antenna.gain == 0.1
    
    # Verify Compression (Mode A)
    # lib.ex should be Mode A (Deep)
    lib_node = Enum.find(nodes, fn n -> String.contains?(n.body.data_ledger.physical_symlink, "lib.ex") end)
    assert lib_node.body.mode == :deep
    assert is_binary(lib_node.body.data_body) # Compressed binary
    
    # Decompress to verify
    assert CMS.NodeBody.decompress(lib_node.body) == "defmodule Lib do end"

    # 5. LiveWire Mutation Test
    # Mutate lib.ex
    Logger.info("Mutating lib.ex...")
    File.write!(Path.join(tmp_dir, "lib.ex"), "defmodule LibModified do end")
    
    # LiveWire is polling every 5s. We wait.
    Process.sleep(6000) 
    
    # Fetch node again
    {:ok, mutated_node} = NodeSupervisor.get_node(lib_node.id)
    
    # Verify ChronoStack
    # Stack in Ledger
    stack = mutated_node.body.data_ledger.chrono_stack
    refute Enum.empty?(stack.snapshots)
    
    latest_snapshot = List.first(stack.snapshots)
    assert latest_snapshot.cause == :livewire_mutation
    
    # Verify Antenna Boost
    # 0.8 initial + 0.2 boost = 1.0
    assert mutated_node.antenna.gain >= 0.99 

    # 6. Spatial Manifold & Descriptor Verification
    # Root node should have Z=0 and an incremented width descriptor (e.g. m4 since 4 items added)
    {:ok, root_node} = NodeSupervisor.get_node(UUID.uuid5(:oid, tmp_dir))
    assert root_node.head.spatial_coords == {0.0, 0.0, 0}
    assert String.starts_with?(root_node.head.width_descriptor, "m")
    assert String.to_integer(String.replace(root_node.head.width_descriptor, "m", "")) > 0

    # Child node should have Z=1 and hierarchical descriptor (e.g. mA0 or similar)
    assert lib_node.head.spatial_coords |> elem(2) == 1
    assert String.length(lib_node.head.width_descriptor) >= 3 # e.g. "mA0" or "mD0"

    # 7. Self-Healing: Deletion Test
    Logger.info("Deleting readme.txt...")
    readme_uuid = Enum.find(nodes, fn n -> String.contains?(n.body.data_ledger.physical_symlink, "readme.txt") end).id
    File.rm!(Path.join(tmp_dir, "readme.txt"))
    
    # Wait for LiveWire to detect deletion
    Process.sleep(6000)
    
    # Verify Node is scoured
    assert NodeSupervisor.get_node(readme_uuid) == {:error, :not_found}
    assert :mnesia.dirty_read(:nodes_table, readme_uuid) == []
  end

  defp wait_for_nodes(target_count, timeout) when timeout <= 0 do
    flunk("Timeout waiting for #{target_count} nodes.")
  end
  defp wait_for_nodes(target_count, timeout) do
    count = length(NodeSupervisor.get_all_active_node_pids())
    if count >= target_count do
      :ok
    else
      Process.sleep(500)
      wait_for_nodes(target_count, timeout - 500)
    end
  end
end
