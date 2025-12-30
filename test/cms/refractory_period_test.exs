defmodule CMS.RefractoryPeriodTest do
  use ExUnit.Case
  require Logger
  alias CMS.{NodeSupervisor, Node, NodeHead, NodeBody, DataHead, DataTail, NodeAntenna}

  setup do
    # Start minimal infrastructure
    ensure_started({Phoenix.PubSub, [name: CMS.PubSub, adapter: Phoenix.PubSub.PG2]})
    ensure_started({Registry, [keys: :unique, name: CMS.NodeRegistry]})
    ensure_started(CMS.ActivationEngine)
    
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

  test "Node ignores subsequent pulses within 2000ms cooldown" do
    uuid = "refractory-node"
    node = create_dummy_node(uuid)
    {:ok, pid} = NodeSupervisor.start_child(node)
    
    # Send first activation
    # Strength 0.9 should trigger fire (T_adj is 0.7 with default inhibition 1.0)
    # total_score = 0.0 (local) + 0.9 * 0.8 * 1.0 * 0.8 (boost: r_origin * f_type * f_context * resistance)
    # wait, boost calculation: 0.9 * 0.8 (semantic) * 1.0 * 0.8 = 0.576
    # 0.576 < 0.7. It won't fire.
    
    # Let's use a higher strength to ensure firing for the refractory test
    # Strength 1.1 (if possible) or just lower the threshold for the test?
    # Actually, let's use strength 1.2 to be safe: 1.2 * 0.8 * 0.8 = 0.768 > 0.7
    send(pid, {:activation, "sender-1", 1.2, :semantic, MapSet.new(), 1})
    
    # Wait for first firing to be processed
    Process.sleep(100)
    
    {:ok, state1} = GenServer.call(pid, :get_state_snapshot)
    first_fired = state1.last_fired
    
    # Send second activation immediately (should be ignored)
    send(pid, {:activation, "sender-2", 1.2, :semantic, MapSet.new(), 1})
    
    Process.sleep(100)
    
    {:ok, state2} = GenServer.call(pid, :get_state_snapshot)
    assert state2.last_fired == first_fired, "Node should NOT have updated last_fired within cooldown"
    
    # Wait for cooldown to expire
    Process.sleep(2000)
    
    # Send third activation (should trigger firing again)
    send(pid, {:activation, "sender-3", 1.2, :semantic, MapSet.new(), 1})
    
    Process.sleep(100)
    
    {:ok, state3} = GenServer.call(pid, :get_state_snapshot)
    assert DateTime.compare(state3.last_fired, first_fired) == :gt, "Node should have fired again after cooldown"
  end

  test "Node does NOT fire when strength is below threshold (Healthy state)" do
    uuid = "threshold-node"
    node = create_dummy_node(uuid)
    {:ok, pid} = NodeSupervisor.start_child(node)
    
    initial_last_fired = node.last_fired
    
    # Send low strength activation
    # Strength 0.5: boost = 0.5 * 0.8 * 0.8 = 0.32. 0.32 < 0.7. Should NOT fire.
    send(pid, {:activation, "low-sender", 0.5, :semantic, MapSet.new(), 1})
    
    Process.sleep(100)
    
    {:ok, state} = GenServer.call(pid, :get_state_snapshot)
    assert state.last_fired == initial_last_fired, "Node should NOT have fired with low strength pulse"
  end

  defp create_dummy_node(uuid) do
    embedding = Nx.broadcast(Nx.tensor(0.1), {384})
    head = NodeHead.new(uuid, embedding, "test-model")
    data_head = DataHead.new("Summary")
    ledger = DataTail.new("/path/to/file", "hash", "text/plain", 1.0)
    body = NodeBody.new(data_head, "Content", ledger)
    antenna = NodeAntenna.new("/path/to/file")
    
    # Start with an old last_fired
    past = DateTime.utc_now() |> DateTime.add(-3600, :second)
    
    Node.new(head, body, antenna, %{}, past, past)
  end
end
