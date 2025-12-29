# verification_script
defmodule ConnectomeVerification do
  alias CMS.Core.Logic.ConnectomeScanner
  alias CMS.Node
  alias CMS.NodeBody
  alias CMS.DataTail
  alias CMS.NodeAntenna
  alias CMS.Edge
  
  def run do
    IO.puts("\n=== Starting Connectome Verification ===\n")
    
    # 1. Skeletal System
    IO.puts("--- Phase 1: Skeletal System ---")
    
    # A. Dynamic Links
    # Create test dir for real file simulation
    test_dir = "/tmp/conn_test_#{System.unique_integer()}"
    File.mkdir_p!(test_dir)
    
    # Mock a binary with libm.so in content
    node_bin = mock_node("binary", "ELF... libm.so.6 ... libs.so ...", test_dir)
    links = ConnectomeScanner.scan_skeleton(node_bin)
    
    check_edge(links, :links_dynamically_to, "libm.so.6")
    
    # B. Symlinks
    # Create real symlink
    test_dir = "/tmp/conn_test_#{System.unique_integer()}"
    File.mkdir_p!(test_dir)
    target = Path.join(test_dir, "target.txt")
    link = Path.join(test_dir, "link.txt")
    File.write!(target, "Target Content")
    File.ln_s!(target, link)
    
    node_link = mock_node_path(link) 
    # Must use correct antenna path for file read_link
    links_sym = ConnectomeScanner.scan_skeleton(node_link)
    
    # We resolve target to UUID. 
    # Verification: check if ANY edge is :symlinks_to.
    if Enum.any?(links_sym, &(&1.type == :symlinks_to)) do
       IO.puts("Symlink Edge: PASSED")
    else
       IO.puts("Symlink Edge: FAILED -> Got #{inspect(links_sym)}")
    end

    # C. Mounts
    node_dev = mock_node_path("/dev/sda1")
    links_mnt = ConnectomeScanner.scan_skeleton(node_dev)
    check_edge(links_mnt, :mounts_on, "/dev/sda1")
    IO.puts("\n--- Phase 2: Immune System ---")
    
    # Mock node with user and group permissions
    ledger = DataTail.new("/tmp/foo", "hash", "mime", 0.5, %{user: "rwx", group: "r-x"}, %{uid: 1000, gid: 2000}) 
    node_immune = %Node{
      id: "test", 
      body: %NodeBody{
         data_ledger: ledger
      }
    }
    
    immune_edges = ConnectomeScanner.scan_immune(node_immune)
    
    # Check OWNED_BY
    if Enum.any?(immune_edges, &(&1.type == :owned_by)) do
      IO.puts("Immune: OWNED_BY Edge: PASSED")
    else
      IO.puts("Immune: OWNED_BY Edge: FAILED")
    end
    
    # Check EXECUTABLE_BY (user has x)
    if Enum.any?(immune_edges, &(&1.type == :executable_by)) do
      IO.puts("Immune: EXECUTABLE_BY Edge: PASSED")
    else
      IO.puts("Immune: EXECUTABLE_BY Edge: FAILED")
    end
    
    # Check for Group Identity Edge
    group_uuid = UUID.uuid5(:oid, "group_identity:2000")
    if Enum.any?(immune_edges, &(&1.target_node_id == group_uuid)) do
      IO.puts("Immune: GROUP IDENTITY Edge: PASSED")
    else
       IO.puts("Immune: GROUP IDENTITY Edge: FAILED -> Got #{inspect(immune_edges)}")
    end
    
    # 3. Nervous System
    IO.puts("\n--- Phase 3: Nervous System ---")
    
    config_content = """
    server {
       root /var/www;
       access_log /var/log/nginx/access.log;
       use_binary /usr/bin/php-fpm;
    }
    """
    node_conf = mock_node("config", config_content, test_dir)
    nervous_edges = ConnectomeScanner.scan_nervous(node_conf)
    
    # Check LOGS_TO
    check_edge(nervous_edges, :logs_to, "log") 
    
    # Check CONFIGURES
    check_edge(nervous_edges, :configures, "bin")

    IO.puts("\n=== Verification Complete ===\n")
    File.rm_rf!(test_dir)
  end
  
  defp mock_node(type, content, test_dir) do
    # Use paths that AnatomyEngine understands
    filename = if type == "binary", do: "mock_tool", else: "mock.conf"
    path = Path.join(test_dir, filename)
    File.write!(path, content)
    
    # If binary, make it executable so TriageProtocol detects it correctly
    if type == "binary", do: File.chmod!(path, 0o755)

    %Node{
      id: UUID.uuid4(),
      body: %NodeBody{
         data_body: content,
         data_ledger: DataTail.new(path, "hash", "mime")
      },
      antenna: %NodeAntenna{salience: 0.5}
    }
  end
  
  defp mock_node_path(path) do
    # Only create file if it's in a safe location like /tmp
    if String.starts_with?(path, "/tmp") do
      unless File.exists?(path) do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "")
      end
    end

    %Node{
      id: UUID.uuid4(),
      antenna: %NodeAntenna{salience: 0.5},
      body: %NodeBody{data_body: "", data_ledger: DataTail.new(path, "h", "m")}
    }
  end

  defp check_edge(edges, type, _context) do
    if Enum.any?(edges, &(&1.type == type)) do
      IO.puts("Edge #{type}: PASSED")
    else
      IO.puts("Edge #{type}: FAILED -> Got #{inspect(edges)}")
    end
  end
end

ConnectomeVerification.run()
