defmodule CMS.SystemMixerTest do
  use ExUnit.Case
  require Logger
  alias CMS.NodeSupervisor
  alias CMS.Services.SystemMixer

  setup do
    # 1. Stop the application first so we can safely wipe data
    Application.stop(:acn_cms)

    # 2. Ensure Mnesia and VectorRouter are clean for the test
    data_dir = Application.get_env(:acn_cms, :data_root)
    File.rm(Path.join(data_dir, "running.pid"))
    File.rm_rf!("priv/data/mnesia_test")
    File.rm_rf!("priv/data/hnsw_indices")
    
    # 3. Start fresh
    Application.start(:acn_cms)
    
    tmp_dir = "/tmp/cdms_mixer_test_#{:rand.uniform(1000000)}"
    File.mkdir_p!(tmp_dir)
    
    on_exit fn ->
      File.rm_rf!(tmp_dir)
    end
    
    {:ok, tmp_dir: tmp_dir}
  end

  test "Two-Pass Genesis establishes syntactic and semantic bonds", %{tmp_dir: tmp_dir} do
    # 1. Create two files with semantic overlap and syntactic dependency
    # File A: The Dependency
    file_a = Path.join(tmp_dir, "auth_logic.ex")
    File.write!(file_a, """
    defmodule AuthLogic do
      @doc "This module handles login and authentication."
      def login(user), do: :ok
    end
    """)

    # File B: The Dependent (Semantic & Syntactic overlap)
    file_b = Path.join(tmp_dir, "user_controller.ex")
    File.write!(file_b, """
    defmodule UserController do
      alias AuthLogic
      @doc "Handles user requests and calls authentication login."
      def handle(conn, params) do
        AuthLogic.login(params["user"])
      end
    end
    """)

    # File C: Python Dependency (e.g. numpy.py)
    file_c = Path.join(tmp_dir, "numpy.py")
    File.write!(file_c, "# NumPy stub")
    
    # File D: Python Dependent
    file_d = Path.join(tmp_dir, "science_script.py")
    File.write!(file_d, "import numpy\n# Using numpy here")

    # 2. Run Pass One (Awakening) - Manually triggering Genesis logic
    Logger.info("Starting Pass One...")
    {:ok, _pid} = NodeSupervisor.start_directory_agent(tmp_dir, nil, {0.0, 0.0, 0}, "m0", [edge_generation: false, notify_pid: self()])
    
    receive do
      {:wavefront_complete, _} -> :ok
    after
      10000 -> flunk("Pass One timed out")
    end

    # Verify nodes exist but have NO syntactic/semantic edges yet
    # We use UUID5 like the agent does
    uuid_a = UUID.uuid5(:oid, file_a)
    uuid_b = UUID.uuid5(:oid, file_b)
    uuid_c = UUID.uuid5(:oid, file_c)
    uuid_d = UUID.uuid5(:oid, file_d)
    
    {:ok, _node_a} = NodeSupervisor.get_node(uuid_a)
    {:ok, node_b} = NodeSupervisor.get_node(uuid_b)
    
    assert Enum.empty?(node_b.tail.syntactic)
    assert Enum.empty?(node_b.tail.semantic)

    # 3. Run Pass Two (Binding)
    Logger.info("Starting Pass Two...")
    SystemMixer.bind_all()

    # 4. Final Verification
    # Reload nodes
    {:ok, node_b_after} = NodeSupervisor.get_node(uuid_b)
    {:ok, node_d_after} = NodeSupervisor.get_node(uuid_d)
    
    # Syntactic check: Should have an :imports edge to Node A
    # User controller aliases AuthLogic, and we registered "AuthLogic" to uuid_a
    assert Enum.any?(node_b_after.tail.syntactic, fn e -> e.target_node_id == uuid_a and e.type == :imports end)
    
    # Python Syntactic check (Via Stem Registration)
    assert Enum.any?(node_d_after.tail.syntactic, fn e -> e.target_node_id == uuid_c and e.type == :imports end)
    
    # Semantic check: Should have a :relates_to edge to Node A due to overlapping docstrings
    assert Enum.any?(node_b_after.tail.semantic, fn e -> e.target_node_id == uuid_a end)
  end
end
