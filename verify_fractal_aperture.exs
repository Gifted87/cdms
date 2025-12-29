# verification_script
defmodule FractalVerification do
  alias CMS.Ingestion.FractalAperture
  alias CMS.Core.Logic.EdgeGenerator
  alias CMS.Node
  alias CMS.NodeHead
  alias CMS.NodeBody
  alias CMS.DataHead
  alias CMS.DataTail

  def run do
    IO.puts("\n=== Starting Fractal Aperture Verification ===\n")
    
    # 1. Bounded Circle
    IO.puts("--- Phase 1: Bounded Circle ---")
    circle_root = "/home/user/project"
    
    check_bound("/home/user/project/lib/foo.ex", circle_root, true)
    check_bound("/home/user/project/README.md", circle_root, true)
    check_bound("/usr/lib/libm.so", circle_root, false)
    check_bound("/tmp/garbage", circle_root, false)

    # 2. Relative Geography & Salience
    IO.puts("\n--- Phase 2: Relative Geography ---")
    
    check_geo("/home/user/project/bin/server", :bin, "High Priority Tool")
    check_geo("/home/user/project/config/sys.config", :etc, "High Priority Config")
    check_geo("/home/user/project/lib/utils.ex", :lib, "Connective Tissue")
    check_geo("/home/user/project/src/main.rs", :general, "Standard")
    
    # Verify Salience Adjustment
    base_salience = 0.5
    s_bin = FractalAperture.adjust_salience(base_salience, :bin)
    s_lib = FractalAperture.adjust_salience(base_salience, :lib)
    
    if s_bin > base_salience, do: IO.puts("Salience Amplification (Bin): PASSED (#{s_bin} > #{base_salience})"), else: IO.puts("Salience Amplification: FAILED")
    if s_lib < base_salience, do: IO.puts("Salience Dampening (Lib): PASSED (#{s_lib} < #{base_salience})"), else: IO.puts("Salience Dampening: FAILED")

    # 3. Ghost Nodes
    IO.puts("\n--- Phase 3: Ghost Nodes (Anchor System) ---")
    
    # Mock a node with an external import
    # Python-like import syntax which EdgeGenerator looks for
    content = """
    import sys
    import /usr/lib/external_lib.so
    """
    
    node = %Node{
       id: UUID.uuid4(),
       head: %NodeHead{embedding: nil},
       body: %NodeBody{
         mode: :deep, 
         data_ledger: %DataTail{physical_symlink: "/home/user/project/script.py", mime_definition: "text/x-python"},
         data_body: content 
       },
       tail: %CMS.NodeTail{hierarchical: [], syntactic: [], semantic: []}
    }
    
    # We need to mock NodeBody.decompress to return our content if EdgeGenerator uses it.
    # Actually, inspecting EdgeGenerator, it calls CMS.NodeBody.decompress(node.body).
    # Since we can't easily mock the module call without Mox, let's rely on logic.
    # EdgeGenerator.generate_syntactic_edges/1 uses find_imports.
    # find_imports for .py uses regex on content.
    
    # We must ensure `CMS.NodeBody` returns the content. 
    # If the content field is raw string and not compressed, decompress might fail if it expects compressed binary.
    # Let's assume for test we just pass the struct such that decompress works or we modify EdgeGenerator to accept string.
    # Wait, EdgeGenerator: `content = CMS.NodeBody.decompress(node.body) || ""`
    # If we can't easily run it, we can test `FractalAperture.create_ghost_node/2` directly.
    
    IO.puts("Directly testing Ghost Node Creation:")
    {uuid, ghost_node, _rec} = FractalAperture.create_ghost_node("/usr/lib/libm.so", node.id)
    
    if ghost_node.head.embedding_model_version == "ghost" and ghost_node.provenance["type"] == "ghost" do
       IO.puts("Ghost Node Structure: PASSED")
       IO.puts("  Anchor: #{ghost_node.body.data_ledger.physical_symlink}")
       IO.puts("  Semantics: Zero-Vector (Shape #{inspect(Nx.shape(ghost_node.head.embedding))})")
    else
       IO.puts("Ghost Node Structure: FAILED")
    end

    IO.puts("\n=== Verification Complete ===\n")
  end

  defp check_bound(path, root, expected) do
    val = FractalAperture.is_inside_circle?(path, root)
    if val == expected do
      IO.puts("Check #{path}: PASSED")
    else
      IO.puts("Check #{path}: FAILED -> Expected #{expected}, Got #{val}")
    end
  end
  
  defp check_geo(path, expected, context) do
    val = FractalAperture.analyze_geography(path)
    if val == expected do
      IO.puts("#{context} (#{path}): PASSED -> #{inspect(expected)}")
    else
      IO.puts("#{context}: FAILED -> Expected #{inspect(expected)}, Got #{inspect(val)}")
    end
  end
end

FractalVerification.run()
