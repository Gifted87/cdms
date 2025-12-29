defmodule CMS.Core.Logic.ConnectomeScanner do
  @moduledoc """
  The Connectome Scanner: Forges Phase 4 Functional Edges.
  Covers the Skeletal, Immune, and Nervous systems of the Digital Body.
  """
  
  alias CMS.{Node, Edge}
  alias CMS.Ingestion.{AnatomyEngine, TriageProtocol}
  alias CMS.VectorRouter
  require Logger

  # --- 1. The Skeletal System (Dependencies) ---
  
  @doc """
  Scans for structural dependencies.
  - LINKS_DYNAMICALLY_TO: Binary -> Library
  - SYMLINKS_TO: Link -> Target
  - MOUNTS_ON: Device -> Directory
  """
  def scan_skeleton(%Node{} = node) do
    path = node.body.data_ledger.physical_symlink
    mime = node.body.data_ledger.mime_definition
    
    # Re-derive triage class if not in provenance (Phase 1 logic)
    # We use identify/1 which re-stats. This is acceptable for local ingestion.
    triage_class = case TriageProtocol.identify(path) do
      {:ok, class} -> class
      _ -> :unknown
    end
    
    organ_type = AnatomyEngine.classify_organ(triage_class, path, mime)
    
    edges = []
    
    # LINKS_DYNAMICALLY_TO: Only for Binary Organs (Executables)
    edges = if organ_type == :binary_organ do
      edges ++ scan_dynamic_links(node)
    else
      edges
    end
    
    # SYMLINKS_TO: All nodes
    edges = edges ++ scan_symlinks(node)
    
    # MOUNTS_ON: Only for Device Interfaces
    edges = if organ_type == :device_interface do
      edges ++ scan_mounts(node)
    else
      edges
    end
    
    edges
  end
  
  defp scan_dynamic_links(node) do
    # Only for Binary Organs
    # In a real implementation, we would parse headers (ELF/PE).
    # Here, we simulate by checking for "lib*.so" strings in content if available.
    
    body_content = CMS.NodeBody.decompress(node.body)
    
    if is_binary(body_content) and byte_size(body_content) > 0 do
       # Simple regex to find library-like strings.
       # Matches: lib[name].so(.version)?
       regex = ~r/lib[a-zA-Z0-9_\-]+\.so(\.[0-9]+)*/
       
       Regex.scan(regex, body_content)
       |> Enum.uniq()
       |> Enum.map(fn [lib_name | _] -> 
          resolve_dependency(lib_name, :links_dynamically_to)
       end)
       |> Enum.reject(&is_nil/1)
    else
       []
    end
  end
  
  defp scan_symlinks(node) do
    path = node.body.data_ledger.physical_symlink
    
    case File.read_link(path) do
      {:ok, target} ->
        # Create edge to target path (might need resolution)
        expanded_target = Path.expand(target, Path.dirname(path))
        [resolve_dependency(expanded_target, :symlinks_to)] |> Enum.reject(&is_nil/1)
      {:error, _} -> []
    end
  end
  
  defp scan_mounts(node) do
    path = node.body.data_ledger.physical_symlink
    
    # Mocking mount check. Real system would read /proc/mounts.
    if String.starts_with?(path, "/dev/sda") do
       [resolve_dependency("/", :mounts_on)] |> Enum.reject(&is_nil/1)
    else
       []
    end
  end

  # --- 2. The Immune System (Authority) ---

  @doc """
  Scans for authority and territory.
  - OWNED_BY: Node -> Identity (User)
  - EXECUTABLE_BY: Identity (User/Group) -> Binary
  """
  def scan_immune(%Node{body: body} = _node) do
    ledger = body.data_ledger
    
    # 1. Ownership (The Territory)
    # Link every File Node to an Identity Node.
    uid = ledger.ownership[:uid]
    owner_edge = if uid, do: create_virtual_edge(uid, :identity, :owned_by), else: nil
    
    # 2. Execution Authority (The Attack Surface)
    # If executable by Group, draws a link from the Group Identity Node.
    gid = ledger.ownership[:gid]
    
    exec_edges = []
    
    # User Execution
    exec_edges = if ledger.permissions[:user] && String.contains?(ledger.permissions[:user], "x") do
       [create_virtual_edge(uid, :identity, :executable_by) | exec_edges]
    else
       exec_edges
    end
    
    # Group Execution
    exec_edges = if ledger.permissions[:group] && String.contains?(ledger.permissions[:group], "x") do
       [create_virtual_edge(gid, :group_identity, :executable_by) | exec_edges]
    else
       exec_edges
    end
    
    # Other/Universal Execution
    exec_edges = if ledger.permissions[:other] && String.contains?(ledger.permissions[:other], "x") do
       [create_virtual_edge("universal", :identity, :executable_by) | exec_edges]
    else
       exec_edges
    end
    
    ([owner_edge] ++ exec_edges) |> Enum.reject(&is_nil/1)
  end

  # --- 3. The Nervous System (Control & Flow) ---

  @doc """
  The Nervous System describes control and flow.
  The system uses a pattern-matching scanner on Configuration Nexuses.
  - CONFIGURES: Config -> Binary (Text file controls binary)
  - LOGS_TO: Config -> Log File (Reveals the Circulatory System)
  """
  def scan_nervous(%Node{} = node) do
    path = node.body.data_ledger.physical_symlink
    mime = node.body.data_ledger.mime_definition
    
    triage_class = case TriageProtocol.identify(path) do
      {:ok, class} -> class
      _ -> :unknown
    end
    
    organ_type = AnatomyEngine.classify_organ(triage_class, path, mime)
    
    # Only for Configuration Nexuses
    if organ_type == :configuration_nexus do
      content = CMS.NodeBody.decompress(node.body)
      
      if content do
        # Pattern-matching scanner on Configuration Nexuses
        Regex.scan(~r/(\/[a-zA-Z0-9_\-\.\/]+)/, content)
        |> Enum.map(fn [path, _] -> path end)
        |> Enum.map(fn target_path ->
           cond do
             # LOGS_TO reveals the Circulatory System
             String.ends_with?(target_path, ".log") -> 
               resolve_dependency(target_path, :logs_to)
               
             # CONFIGURES shows which text file controls which binary
             String.starts_with?(target_path, "/bin") or String.starts_with?(target_path, "/usr/bin") -> 
               resolve_dependency(target_path, :configures)
               
             true -> nil
           end
        end)
        |> Enum.reject(&is_nil/1)
      else
        []
      end
    else
      []
    end
  end
  
  # --- Helpers ---
  
  defp resolve_dependency(target, type) do
    # Resolve target string to UUID.
    # LINKS_DYNAMICALLY_TO creates rigid links to Library Nodes (or Ghost Nodes).
    # If this link breaks, the organ dies.
    
    case VectorRouter.resolve_path(target) do
      {:ok, uuid} -> Edge.new(uuid, type, 1.0)
      _ -> 
         if String.contains?(target, "/") or String.starts_with?(target, "lib") do
           # Generate Ghost on the fly for paths or libraries
           {ghost_uuid, _, _} = CMS.Ingestion.FractalAperture.create_ghost_node(target, "scanner")
           Edge.new(ghost_uuid, type, 1.0)
         else
           nil
         end
    end
  end
  
  defp create_virtual_edge(id, type, edge_type) do
    # Virtual Nodes for Identities are indexed by "identity:<uid>" or "group_identity:<gid>"
    prefix = if type == :group_identity, do: "group_identity", else: "identity"
    uuid = UUID.uuid5(:oid, "#{prefix}:#{id}")
    Edge.new(uuid, edge_type, 1.0)
  end
end
