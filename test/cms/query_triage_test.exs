defmodule CMS.QueryTriageTest do
  use ExUnit.Case
  require Logger
  
  setup do
    # Ensure services are running
    ensure_started({Phoenix.PubSub, name: CMS.PubSub})
    ensure_started({Registry, keys: :unique, name: CMS.NodeRegistry})
    ensure_started(CMS.SymbolicIndex)
    ensure_started(CMS.VectorRouter)
    :ok
  end
  
  defp ensure_started(module_or_spec) do
    case start_supervised(module_or_spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, _} =err -> err
    end
  end
  
  describe "Query Triage Routing" do
    test "detects path queries (Mode A)" do
      assert {:symbolic, _} = CMS.QueryTriage.route("/home/user/file.ex")
      assert {:symbolic, _} = CMS.QueryTriage.route("~/project/lib/app.ex")
      assert {:symbolic, _} = CMS.QueryTriage.route("./relative/path.ex")
    end
    
    test "detects filename queries (Mode B)" do
      assert {:nominal, "config.json"} = CMS.QueryTriage.route("config.json")
      assert {:nominal, "app.ex"} = CMS.QueryTriage.route("app.ex")
      assert {:nominal, "README.md"} = CMS.QueryTriage.route("README.md")
    end
    
    test "detects natural language queries (Mode C)" do
      assert {:semantic, _} = CMS.QueryTriage.route("how does hebbian learning work?")
      assert {:semantic, _} = CMS.QueryTriage.route("what is the activation engine")
      assert {:semantic, _} = CMS.QueryTriage.route("show me files about cognition")
    end
    
    test "allows manual mode override" do
      assert {:symbolic, _} = CMS.QueryTriage.route("anything", mode: :symbolic)
      assert {:nominal, _} = CMS.QueryTriage.route("anything", mode: :nominal)
      assert {:semantic, _} = CMS.QueryTriage.route("anything", mode: :semantic)
    end
  end
  
  describe "Mode A: Symbolic Index" do
    test "returns empty results for non-existent paths" do
      {:ok, :symbolic, results} = CMS.QueryTriage.execute("/non/existent/path.ex")
      assert results == []
    end
  end
  
  describe "Mode B: Nominal Index" do
    test "returns empty results for non-registered names" do
      {:ok, :nominal, results} = CMS.QueryTriage.execute("nonexistent_file.ex")
      assert results == []
    end
  end
  
  describe "Mode C: Semantic Search" do
    test "handles embedding failures gracefully" do
      # This will fail if embedder is not configured
      case CMS.QueryTriage.execute("test semantic query") do
        {:ok, :semantic, _results} -> assert true
        {:error, :embedding_failed} -> assert true  # Expected if no embedder
        _ -> flunk("Unexpected result")
      end
    end
  end
end
