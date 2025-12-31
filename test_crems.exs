# test_crems.exs
require Logger

defmodule CREMSTester do
  def run do
    IO.puts("\n🔎 --- CREMS DIAGNOSTIC PROTOCOL ---\n")

    # 1. Check Mother Node (The Root)
    IO.write("🔎 Waiting for Mother Node genesis...")
    case wait_for_node("mother-0000-0000-0000-000000000001", 15) do
      pid when is_pid(pid) ->
        IO.puts(" ✅ ALIVE. PID: #{inspect(pid)}")
        inspect_node(pid, "Mother Node")
      _ ->
        IO.puts(" ❌ NOT FOUND. Genesis failed.")
        exit(:genesis_failed)
    end

    # 2. Check Process Swarm (PID Nodes)
    nodes = Registry.select(CMS.NodeRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    
    pid_nodes = Enum.filter(nodes, fn {id, _} -> is_binary(id) and String.starts_with?(id, "pid-node-") end)
    beam_nodes = Enum.filter(nodes, fn {id, _} -> is_binary(id) and String.starts_with?(id, "beam-node-") end)

    IO.puts("\n📊 --- SWARM CENSUS ---")
    IO.puts("Total Nodes: #{length(nodes)}")
    IO.puts("OS Process Nodes (pid-node-*): #{length(pid_nodes)}")
    IO.puts("Erlang BEAM Nodes (beam-node-*): #{length(beam_nodes)}")

    if length(pid_nodes) > 0 do
      {sample_id, sample_pid} = List.first(pid_nodes)
      IO.puts("\n🔬 --- BIOPSY: #{sample_id} ---")
      inspect_node(sample_pid, sample_id)
    else
      IO.puts("⚠️  No OS processes found. Check permissions or /proc accessibility.")
    end

    # 3. Necrosis Verification
    test_necrosis()
  end

  def test_necrosis do
    IO.puts("\n💀 --- NECROSIS PROTOCOL VERIFICATION ---")
    
    # 1. Start a dummy process
    port = Port.open({:spawn, "sleep 60"}, [:binary])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    node_id = "pid-node-#{os_pid}"
    
    IO.puts("   [1/4] Spawned dummy process (sleep 60, PID: #{os_pid})")
    
    # 2. Wait for Modelling
    IO.write("   [2/4] Waiting for Swarm discovery...")
    node_pid = wait_for_node(node_id)
    IO.puts(" Linked: #{inspect(node_pid)}")
    
    # 3. Trigger Death
    IO.puts("   [3/4] Terminating process #{os_pid} (Triggering Necrosis)...")
    Port.close(port) # Closes the sleep process
    
    # 4. Verify Ghost Transition
    IO.write("   [4/4] Verifying Autopsy and Ghost Transition...")
    wait_for_ghost(node_id, node_pid)
    IO.puts(" SUCCESS")
  end

  defp wait_for_node(node_id, attempts \\ 60) do
    case Registry.lookup(CMS.NodeRegistry, node_id) do
      [{pid, _}] -> pid
      [] when attempts > 0 ->
        IO.write(".")
        Process.sleep(1000)
        wait_for_node(node_id, attempts - 1)
      [] ->
        IO.puts("\n❌ TIMEOUT: ModellingAgent did not pick up PID in time.")
        exit(:timeout)
    end
  end

  defp wait_for_ghost(node_id, pid, attempts \\ 15) do
    if Process.alive?(pid) do
      try do
        {:ok, node} = GenServer.call(pid, :get_state_snapshot, 5000)
        if node.body.natural_language_fact =~ "DECEASED" do
          IO.puts("\n      ✅ Forensic Detail: #{node.body.natural_language_fact}")
          :ok
        else
          IO.write(".")
          Process.sleep(1000)
          wait_for_ghost(node_id, pid, attempts - 1)
        end
      catch
        _ -> 
          IO.puts("\n❌ NodeActor died instead of transitioning to Ghost.")
          exit(:failure)
      end
    else
      IO.puts("\n❌ NodeActor is DEAD. Expected Ghost state.")
      exit(:failure)
    end
  end

  defp inspect_node(pid, label) do
    try do
      # 3. Physiology Check (Heartbeat)
      {:ok, node} = GenServer.call(pid, :get_state_snapshot, 5000)
      
      body = node.body
      telemetry = body.fid_telemetry || %{}
      
      IO.puts("""
      Identity: #{body.natural_language_fact}
      State: #{inspect(body.fid_state)}
      Metabolism (Energy): #{body.fid_agility}
      
      [Physiology]
      Stress: #{body.fid_stress} (CPU/Queue Pressure)
      Strain: #{body.fid_strain} (RAM Usage)
      Telemetry: RAM=#{div(Map.get(telemetry, :ram_bytes, 0), 1024)}KB | CPU=#{Map.get(telemetry, :cpu_usage, 0)}%
      """)
      
      # 4. Connectome Check (Edges)
      comm_edges = node.tail.communication_edges
      hier_edges = node.tail.hierarchical_edges
      
      IO.puts("[Connectome]")
      IO.puts("Parents/Children: #{length(hier_edges)}")
      IO.puts("Active Connections: #{length(comm_edges)}")
      
      if length(comm_edges) > 0 do
        IO.puts("  -> Sample Link: #{inspect(List.first(comm_edges))}")
      end
      
    catch
      e -> IO.puts("❌ Failed to biopsy #{label}: #{inspect(e)}")
    end
  end
end

# Execute
CREMSTester.run()