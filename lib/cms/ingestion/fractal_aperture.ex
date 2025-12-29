defmodule CMS.Ingestion.FractalAperture do
  @moduledoc """
  The Fractal Aperture: Scope & Context Management.
  
  Handles:
  1. The Bounded Circle: Defining scope boundaries.
  2. The Anchor System: Creating Ghost Nodes for external references.
  3. Relative Geography: Inferring semantic priority from directory structure.
  """
  
  alias CMS.{Node, NodeHead, NodeBody, NodeAntenna, DataHead, DataTail, ChronoStack}
  require Logger

  # --- 1. The Bounded Circle ---

  @doc """
  Checks if a path is within the Bounded Circle defined by `circle_root`.
  """
  def is_inside_circle?(path, circle_root) do
    path = Path.expand(path)
    root = Path.expand(circle_root)
    String.starts_with?(path, root)
  end

  # --- 2. The Anchor System (Ghost Nodes) ---

  @doc """
  Creates a Ghost Node: A simplified marker for an external dependency.
  It has no body (content), no history, but acts as a rigid anchor.
  """
  def create_ghost_node(path, origin_node_id) do
    # Unique ID based on path hash
    uuid = UUID.uuid5(:oid, path)
    filename = Path.basename(path)
    
    # Check if already exists? (Generator logic handles this via Mnesia usually, 
    # but here we return the struct for spawning)

    # Ghost Node Structure
    # Head: Minimal
    spatial_coords = {0.0, 0.0, -1} # "Outside" or below the plane
    embedding = Nx.broadcast(Nx.tensor(0.0), {384}) # Zero semantics
    
    head = NodeHead.new(uuid, embedding, "ghost", 0.0, spatial_coords, "ghost")
    
    # Data Head: Minimal info
    data_head = DataHead.new("Ghost Node Anchor for #{filename}", ["External", "Dependency", "Ghost"])
    
    # Data Ledger: External location
    # Since we can't read it, we guess mime or use generic.
    data_ledger = DataTail.new(path, UUID.uuid5(:oid, "ghost"), "application/octet-stream", 0.1)
    
    # Body: Empty
    body = NodeBody.new(data_head, nil, data_ledger, :shallow)
    
    # Antenna: Very low salience
    antenna = NodeAntenna.new(path, 0.1)
    
    # Provenance
    provenance = %{"type" => "ghost", "anchored_by" => origin_node_id}

    node = Node.new(head, body, antenna, provenance)
    
    # We must construct a valid record for Mnesia too
    # We cheat slightly by not having full history, but it's a Ghost.
    record = {:nodes_table, uuid, UUID.uuid5(:oid, path), nil, head, body, node.tail, ChronoStack.new(), provenance, antenna}
    
    {uuid, node, record}
  end

  # --- 3. Relative Geography ---

  @doc """
  Analyzes relative geography of a path to infer semantic function.
  
  Returns:
  - `:bin` (High Priority Tool)
  - `:etc` (High Priority Config)
  - `:lib` (Connective Tissue / Low Priority)
  - `:general` (Standard)
  """
  def analyze_geography(path) do
    parts = Path.split(path)
    
    # We look for specific markers in the path parts.
    # Priority: bin > etc > lib.
    
    cond do
      "bin" in parts or "sbin" in parts -> :bin
      "etc" in parts or "config" in parts -> :etc
      "lib" in parts or "node_modules" in parts or "deps" in parts or "vendor" in parts -> :lib
      true -> :general
    end
  end

  @doc """
  Adjusts salience based on Relative Geography.
  
  - `:bin` -> Amplify (Tools)
  - `:etc` -> Amplify (Nervous System)
  - `:lib` -> Dampen (Connective Tissue)
  """
  def adjust_salience(salience, geography) do
    case geography do
      :bin -> min(salience * 1.5, 1.0)
      :etc -> min(salience * 1.2, 1.0)
      :lib -> salience * 0.5 # "Lower their semantic volume"
      :general -> salience
    end
  end
end
