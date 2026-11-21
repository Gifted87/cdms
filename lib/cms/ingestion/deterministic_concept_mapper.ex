defmodule CMS.Ingestion.DeterministicConceptMapper do
  @moduledoc """
  Generates semantic concepts from deterministic analysis (AST + Metadata).
  Now uses full AST traversal to detect architectural roles and traits.
  """
  require Logger
  alias CMS.Ingestion.CodeGraphEngine

  @doc """
  Maps full AST and file metadata to a list of concepts.
  """
  def map_concepts(path, content, ast) do
    lang = CodeGraphEngine.language_from_path(path)
    
    # 1. Identify Architectural Traits (AST-based)
    traits = detect_traits(lang, ast)
    
    # 2. Map Traits to Dimensions
    dimension_concepts = map_traits_to_dimensions(traits)
    
    # 3. Structural Metadata (Language/Platform)
    struct_concepts = get_structural_concepts(lang, path, content)
    
    # 4. Functional Summary (from AST structure)
    func_concepts = get_functional_concepts(ast)

    (dimension_concepts ++ struct_concepts ++ func_concepts)
    |> Enum.uniq()
    |> Enum.take(25)
  end

  # --- Trait Detection (Language Specific) ---

  defp detect_traits(:elixir, ast) do
    traits = []
    
    # Use nodes
    use_nodes = CodeGraphEngine.find_all_nodes_by_type(ast, "call")
                |> Enum.filter(fn n -> 
                   Enum.any?(n[:children] || [], &(&1[:content] == "use"))
                end)
    
    traits = if has_use?(use_nodes, "GenServer"), do: [:genserver | traits], else: traits
    traits = if has_use?(use_nodes, "Phoenix.Controller"), do: [:controller, :web_api | traits], else: traits
    traits = if has_use?(use_nodes, "Ecto.Schema"), do: [:model, :persistence | traits], else: traits
    traits = if has_use?(use_nodes, "Phoenix.LiveView"), do: [:liveview, :ui_component | traits], else: traits
    
    # Call patterns
    calls = CodeGraphEngine.find_all_nodes_by_type(ast, "call")
    traits = if has_call_to?(calls, "Repo"), do: [:database_io | traits], else: traits
    traits = if has_call_to?(calls, "HTTP"), do: [:network_io | traits], else: traits
    
    traits
  end

  defp detect_traits(:python, ast) do
    traits = []
    classes = CodeGraphEngine.find_all_nodes_by_type(ast, "class_definition")
    
    # Detect Django/Flask patterns in inheritance
    traits = if Enum.any?(classes, &String.contains?(&1[:content], "models.Model")), do: [:model, :persistence | traits], else: traits
    traits = if Enum.any?(classes, &String.contains?(&1[:content], "View")), do: [:controller, :web_api | traits], else: traits
    
    traits
  end

  defp detect_traits(:javascript, ast) do
    traits = []
    # Detect React, Express, etc.
    content = ast[:content] || ""
    traits = if String.contains?(content, "React"), do: [:ui_component, :frontend | traits], else: traits
    traits = if String.contains?(content, "express"), do: [:web_api, :backend | traits], else: traits
    
    traits
  end

  defp detect_traits(_lang, _ast), do: []

  # --- Dimension Mapping ---

  defp map_traits_to_dimensions(traits) do
    Enum.flat_map(traits, fn
      :genserver -> ["pattern:stateful_actor", "role:background_process"]
      :controller -> ["role:web_controller", "dimension:interface"]
      :web_api -> ["dimension:network", "role:api_provider"]
      :model -> ["role:data_model", "dimension:persistence"]
      :persistence -> ["dimension:persistence"]
      :ui_component -> ["role:ui_component", "dimension:visual"]
      :liveview -> ["pattern:real_time_ui", "dimension:visual"]
      :database_io -> ["system:io", "dimension:persistence", "resource:database"]
      :network_io -> ["system:io", "dimension:network", "resource:http"]
      _ -> []
    end)
  end

  # --- Structural & Functional Concepts ---

  defp get_structural_concepts(lang, path, content) do
    base = ["lang:#{lang}", "platform:#{get_platform(lang)}"]
    
    lines = String.split(content, "\n") |> length()
    scale = cond do
      lines > 500 -> ["scale:large", "complexity:high"]
      lines > 100 -> ["scale:medium", "complexity:standard"]
      true -> ["scale:small", "complexity:low"]
    end
    
    base ++ scale ++ [ "ext:#{Path.extname(path) |> String.replace(".", "")}" ]
  end

  defp get_functional_concepts(ast) do
    # Extract top-level module/class names as concepts
    definitions = CodeGraphEngine.find_all_nodes_by_type(ast, "class_definition") ++
                  CodeGraphEngine.find_all_nodes_by_type(ast, "module_definition") # Adjust per lang if needed
    
    # Or just use the relationships logic if we want to keep it simple but AST-based
    # For now, let's just look for "important" identifiers
    []
  end

  defp get_platform(:elixir), do: "beam"
  defp get_platform(:python), do: "python3"
  defp get_platform(l) when l in [:javascript, :typescript], do: "v8_node"
  defp get_platform(_), do: "cross_platform"

  # --- Helpers ---

  defp has_use?(use_nodes, pattern) do
    Enum.any?(use_nodes, &String.contains?(&1[:content], pattern))
  end

  defp has_call_to?(call_nodes, pattern) do
    Enum.any?(call_nodes, &String.contains?(&1[:content], pattern))
  end
end
