# verification_script
defmodule PhysiologyVerification do
  alias CMS.Core.Logic.PhysiologyEngine
  alias CMS.NodeSupervisor
  alias CMS.Node
  alias CMS.Ingestion.FileIngestionTask
  
  def run do
    IO.puts("\n=== Starting Phase 5: Physiology Verification ===\n")
    
    test_dir = "/tmp/phys_test_#{System.unique_integer()}"
    File.mkdir_p!(test_dir)
    
    # 1. Bone Node Test (Config)
    IO.puts("--- Phase 1: Bone Node Metabolism ---")
    bone_path = Path.join(test_dir, "bone.conf")
    File.write!(bone_path, "initial content")
    {:ok, bone_id} = FileIngestionTask.ingest(bone_path, nil)
    
    node_bone = get_node_safe(bone_id)
    if node_bone.body.data_ledger.metabolism == :static_bone do
      IO.puts("Bone Nodes classification: PASSED")
    else
      IO.puts("Bone Nodes classification: FAILED -> Got #{node_bone.body.data_ledger.metabolism}")
    end

    # 2. Blood Node Test (Log)
    IO.puts("\n--- Phase 2: Blood Node Metabolism & Buffering ---")
    blood_path = Path.join(test_dir, "blood.log")
    File.write!(blood_path, "line 1\n")
    {:ok, blood_id} = FileIngestionTask.ingest(blood_path, nil)
    
    node_blood = get_node_safe(blood_id)
    if node_blood.body.data_ledger.metabolism == :fluid_blood do
      IO.puts("Blood Nodes classification: PASSED")
    else
      IO.puts("Blood Nodes classification: FAILED -> Got #{node_blood.body.data_ledger.metabolism}")
    end

    # 3. Mutation Catch-and-Buffer
    IO.puts("\n--- Phase 3: Buffering Mutation (Inhibiting Persistence) ---")
    
    # Simulate rapid writes
    File.write!(blood_path, "line 2\n")
    # Wait for LiveWire poll/mutate
    :timer.sleep(2000) 
    
    # Verify Mnesia has NOT updated yet (remains "line 1")
    mnesia_node = get_node_from_store(blood_id)
    if mnesia_node.body.data_body == "line 1\n" do
      IO.puts("Persistence Inhibition (Buffering): PASSED")
    else
      IO.puts("Persistence Inhibition (Buffering): FAILED -> Mnesia updated prematurely with: #{inspect(mnesia_node.body.data_body)}")
    end

    # 4. Heartbeat Pulse
    IO.puts("\n--- Phase 4: The 5-Minute Heartbeat Pulse ---")
    PhysiologyEngine.trigger_heartbeat()
    :timer.sleep(1000) # Wait for heartbeat processing
    
    mnesia_node_after = get_node_from_store(blood_id)
    if mnesia_node_after.body.data_body == "line 2\n" do
      IO.puts("Heartbeat Persistence (Time-Boxing): PASSED")
    else
      IO.puts("Heartbeat Persistence: FAILED -> Mnesia NOT updated after heartbeat.")
    end
    
    # 5. ChronoStack Depth Truncation
    IO.puts("\n--- Phase 5: ChronoStack Depth Truncation ---")
    
    # Simulate many pulses. Blood nodes limit to 10.
    simulate_pulses(blood_id, blood_path, 15)
    
    final_node = get_node_safe(blood_id)
    stack_size = length(final_node.body.data_ledger.chrono_stack.snapshots)
    
    if stack_size <= 10 do
      IO.puts("ChronoStack Truncation (Max 10): PASSED (Size: #{stack_size})")
    else
      IO.puts("ChronoStack Truncation: FAILED -> Found #{stack_size} snapshots")
    end

    IO.puts("\n=== Physiology Verification Complete ===\n")
    File.rm_rf!(test_dir)
  end

  defp get_node_safe(id) do
    case NodeSupervisor.get_node(id) do
      {:ok, node} -> node
      _ -> raise "Node not found in registry"
    end
  end

  defp get_node_from_store(id) do
    case :mnesia.dirty_read(:nodes_table, id) do
      [{:nodes_table, id, _hash, _p_uuid, head, body, tail, stack, provenance, antenna}] ->
         # Reconstruct like Hydrator
         %Node{
           id: id,
           head: head,
           body: %{body | data_ledger: %{body.data_ledger | chrono_stack: stack}},
           tail: tail,
           antenna: antenna,
           provenance: provenance
         }
      _ -> raise "Node not found in Mnesia"
    end
  end

  defp simulate_pulses(id, path, count) do
    Enum.each(1..count, fn i -> 
       File.write!(path, "pulse #{i}")
       PhysiologyEngine.buffer_blood(id, "pulse #{i}") # Direct buffer to speed up test
       PhysiologyEngine.trigger_heartbeat()
       :timer.sleep(100)
    end)
  end
end

PhysiologyVerification.run()
