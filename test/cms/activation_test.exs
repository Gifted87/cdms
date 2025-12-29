defmodule CMS.ActivationTest do
  use ExUnit.Case
  require Logger
  alias CMS.{NodeActor, NodeSupervisor, Node, NodeHead, NodeBody, DataHead, DataTail, NodeAntenna, Edge}

  setup do
    # Start minimal infrastructure for activation tests
    ensure_started({Phoenix.PubSub, [name: CMS.PubSub, adapter: Phoenix.PubSub.PG2]})
    ensure_started({Registry, [keys: :unique, name: CMS.NodeRegistry]})
    ensure_started(CMS.ActivationEngine)
    
    # We need LogAppender and EpochManager for the firing logs
    # but since we want to avoid Mnesia hassle, we'll just mock/stub or skip them if possible.
    # Actually, NodeActor calls them. Let's start a stub LogAppender if possible, 
    # or just start the real one but handle its dependencies.
    
    # Start all Hebbian shards
    Enum.each(0..31, fn i ->
      ensure_started({CMS.RegionalHebbianBuffer, i})
    end)
    
    ensure_started(CMS.NodeSupervisor)
    
    :ok
  end

  defp ensure_started(module_or_spec) do
    case start_supervised(module_or_spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, _} = err -> err
    end
  end

  test "Node Firing updates last_fired" do
    uuid = "node-1"
    node = create_dummy_node(uuid)
    {:ok, pid} = NodeSupervisor.start_child(node)
    
    {:ok, node_info} = GenServer.call(pid, :get_state_snapshot)
    initial_last_fired = node_info.last_fired
    
    GenServer.cast(pid, :fire)
    
    # Wait for processing
    Process.sleep(500)
    
    {:ok, state} = GenServer.call(pid, :get_state_snapshot)
    Logger.info("[TRACE] Node #{uuid} last_fired after: #{inspect(state.last_fired)}")
    assert DateTime.compare(state.last_fired, initial_last_fired) == :gt
  end

  test "Signal Propagation between connected nodes" do
    uuid_a = "node-a"
    uuid_b = "node-b"
    
    # Node A links to Node B
    edge = Edge.new(uuid_b, :semantic, 0.9)
    node_a = create_dummy_node(uuid_a)
    # Give Node A max gain to ensure propagation triggers Node B
    node_a = %{node_a | antenna: %{node_a.antenna | gain: 1.0}}
    node_a = %{node_a | tail: CMS.NodeTail.add_edge(node_a.tail, edge)}
    
    node_b = create_dummy_node(uuid_b)
    
    {:ok, _pid_a} = NodeSupervisor.start_child(node_a)
    {:ok, _pid_b} = NodeSupervisor.start_child(node_b)
    
    # Fire Node A
    NodeActor.fire(uuid_a)
    
    # Wait for propagation
    Process.sleep(200)
    
    # Verify Node B received activation
    # We can check Node B's state for last_activation_times
    # But wait, NodeActor.get_state_snapshot returns state.node, not the actor state.
    # Let's add a way to get the full actor state or check behavior.
    # In NodeActor, strength > 0.7 triggers firing. 0.9 * 0.8 * 1.0 (gain * salience) = 0.72.
    # This should trigger Node B to fire too.
    
    {:ok, state_b} = GenServer.call(via_tuple(uuid_b), :get_state_snapshot)
    assert DateTime.compare(state_b.last_fired, node_b.last_fired) == :gt

    # Verify Hebbian learning (Cells that fire together, wire together)
    # Node A activated Node B, within a short window, link A -> B is strengthened.
    # We check the ETS buffer directly.
    # NodeActor hardcodes region 0 currently, so it goes to shard 0.
    
    # Wait for the async GenServer.cast to reach the buffer
    Process.sleep(200)
    
    key = {uuid_a, uuid_b}
    case :ets.lookup(:hebbian_buffer_0, key) do
      [{^key, delta}] ->
         assert delta > 0
         IO.puts("[TEST_TRACE] Hebbian Delta for #{uuid_a} -> #{uuid_b}: #{delta}")
      [] ->
         flunk("Hebbian update for #{inspect(key)} not found in :hebbian_buffer_0")
    end
  end

  defp create_dummy_node(uuid) do
    embedding = Nx.broadcast(Nx.tensor(0.1), {384})
    head = NodeHead.new(uuid, embedding, "test-model")
    data_head = DataHead.new("Summary")
    ledger = DataTail.new("/path/to/file", "hash", "text/plain", 1.0) # Max salience
    body = NodeBody.new(data_head, "Content", ledger)
    antenna = NodeAntenna.new("/path/to/file") # Gain 0.8 for source
    
    # Use an older timestamp to ensure comparison > works
    past = DateTime.utc_now() |> DateTime.add(-10, :second)
    
    Node.new(head, body, antenna, past, past)
  end

  defp via_tuple(id), do: {:via, Registry, {CMS.NodeRegistry, id}}
end
