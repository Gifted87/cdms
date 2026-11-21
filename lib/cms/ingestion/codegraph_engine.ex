defmodule CMS.Ingestion.CodeGraph.Native do
  @moduledoc """
  Low-level NIF interface for tree-sitter based AST parsing and indexing.
  """
  use Rustler, otp_app: :acn_cms, crate: "codegraph_engine"

  def parse_source(_lang, _source), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule CMS.Ingestion.CodeGraphEngine do
  @moduledoc """
  High-level interface for managing the CodeGraph.
  Orchestrates relationships extraction from ASTs.
  """
  require Logger

  alias CMS.Ingestion.CodeGraph.Native

  def nif_supported?(lang) do
    lang in [:elixir, :python, :javascript, :typescript, :java, :csharp, :go, :rust, :cpp, :php]
  end

  @doc """
  Parses a source file and returns its AST structure.
  """
  def parse_file(path) do
    with {:ok, source} <- File.read(path),
         lang <- language_from_path(path) do
      # The NIF returns the AST map directly or an {:error, reason} tuple
      case Native.parse_source(lang, source) do
        {:error, reason} -> {:error, reason}
        ast when is_map(ast) -> {:ok, ast}
        other -> {:error, other}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extracts semantic relationships from an AST node.
  Returns a list of {type, from, to} tuples.
  """
  def extract_relationships(node, path, stack \\ []) do
    lang = language_from_path(path)
    
    case lang do
      :elixir -> extract_elixir(node, path, stack)
      :python -> extract_python(node, path, stack)
      lang when lang in [:javascript, :typescript] -> extract_javascript(node, path, stack)
      lang when lang in [:java, :csharp] -> extract_java_cs(node, path, stack)
      :go -> extract_go(node, path, stack)
      :rust -> extract_rust(node, path, stack)
      :cpp -> extract_cpp(node, path, stack)
      :php -> extract_php(node, path, stack)
      _ -> traverse_children(node, path, stack)
    end
  end

  # --- PHP Extraction ---
  defp extract_php(node, path, stack) do
    case node[:node_type] do
      type when type in ["class_declaration", "interface_declaration", "trait_declaration"] ->
        name = find_child_content(node, "name")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "function_declaration" ->
        name = find_child_content(node, "name")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "method_declaration" ->
        name = find_child_content(node, "name")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "namespace_definition" ->
        name = find_child_content(node, "name")
        traverse_children(node, path, stack ++ [name])
      type when type in ["include_expression", "require_expression"] ->
        source = node[:content] |> String.replace(~r/^(include|require)(_once)?\s*['"]?|['"]?;?$/, "")
        [{"depends_on", path, source}] ++ traverse_children(node, path, stack)
      _ -> traverse_children(node, path, stack)
    end
  end

  # --- Elixir Extraction ---
  defp extract_elixir(node, path, stack) do
    case node[:node_type] do
      "call" ->
        cond do
          is_defmodule_call?(node) ->
            name = find_module_name_in_call(node)
            [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])

          is_dependency_call?(node) ->
            names = find_all_aliases_in_call(node)
            Enum.map(names, fn name -> {"depends_on", path, name} end) ++ traverse_children(node, path, stack)

          is_module_call?(node) ->
            case find_module_in_dot_call(node) do
              nil -> traverse_children(node, path, stack)
              name -> [{"calls", path, name}] ++ traverse_children(node, path, stack)
            end

          true -> traverse_children(node, path, stack)
        end
      _ -> traverse_children(node, path, stack)
    end
  end

  # --- Python Extraction ---
  defp extract_python(node, path, stack) do
    case node[:node_type] do
      "class_definition" ->
        name = find_child_content(node, "identifier")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "function_definition" ->
        name = find_child_content(node, "identifier")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "import_statement" ->
        names = find_all_children_content(node, "dotted_name")
        Enum.map(names, fn n -> {"depends_on", path, n} end) ++ traverse_children(node, path, stack)
      "import_from_statement" ->
        module = find_child_content(node, "dotted_name")
        [{"depends_on", path, module}] ++ traverse_children(node, path, stack)
      "call" ->
        name = find_child_content(node, "identifier") || find_attribute_call(node)
        case name do
          nil -> traverse_children(node, path, stack)
          name -> [{"calls", path, name}] ++ traverse_children(node, path, stack)
        end
      _ -> traverse_children(node, path, stack)
    end
  end

  # --- JS/TS Extraction ---
  defp extract_javascript(node, path, stack) do
    case node[:node_type] do
      type when type in ["class_declaration", "function_declaration", "method_definition"] ->
        name = find_child_content(node, "identifier") || find_child_content(node, "property_identifier")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "import_statement" ->
        source = find_child_content(node, "string") |> String.replace(~r/^["']|["']$/, "")
        [{"depends_on", path, source}] ++ traverse_children(node, path, stack)
      "call_expression" ->
        case find_member_call(node) do
          nil -> traverse_children(node, path, stack)
          name -> [{"calls", path, name}] ++ traverse_children(node, path, stack)
        end
      _ -> traverse_children(node, path, stack)
    end
  end

  # --- Java/C# Extraction ---
  defp extract_java_cs(node, path, stack) do
    case node[:node_type] do
      type when type in ["class_declaration", "interface_declaration", "enum_declaration"] ->
        name = find_child_content(node, "identifier")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "method_declaration" ->
        name = find_child_content(node, "identifier")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "import_declaration" ->
        name = find_child_content(node, "scoped_identifier") || find_child_content(node, "identifier")
        [{"depends_on", path, name}] ++ traverse_children(node, path, stack)
      "method_invocation" ->
        name = find_child_content(node, "identifier")
        [{"calls", path, name}] ++ traverse_children(node, path, stack)
      _ -> traverse_children(node, path, stack)
    end
  end

  # --- Go Extraction ---
  defp extract_go(node, path, stack) do
    case node[:node_type] do
      "function_declaration" ->
        name = find_child_content(node, "identifier")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "method_declaration" ->
        # Go methods have a receiver: func (r *Receiver) Method()
        receiver = find_child_node(node, "parameter_list") 
                   |> find_child_node("parameter_declaration")
                   |> find_child_node("type_identifier")
                   |> case do nil -> nil; n -> n[:content] end
        name = find_child_content(node, "field_identifier")
        full = if receiver, do: "#{receiver}.#{name}", else: name
        [{"defines", path, full_name(stack, full)}] ++ traverse_children(node, path, stack ++ [full])
      "import_spec" ->
        path_name = find_child_content(node, "interpreted_string_literal") |> String.replace("\"", "")
        [{"depends_on", path, path_name}] ++ traverse_children(node, path, stack)
      "call_expression" ->
        case find_selector_call(node) do
          nil -> traverse_children(node, path, stack)
          name -> [{"calls", path, name}] ++ traverse_children(node, path, stack)
        end
      _ -> traverse_children(node, path, stack)
    end
  end

  # --- Rust Extraction ---
  defp extract_rust(node, path, stack) do
    case node[:node_type] do
      "impl_item" ->
        # impl Blocks are interesting: impl MyStruct { ... }
        type = find_child_content(node, "type_identifier")
        traverse_children(node, path, stack ++ [type])
      type when type in ["function_item", "struct_item", "enum_item", "trait_item"] ->
        name = find_child_content(node, "identifier")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "use_declaration" ->
        path_name = node[:content] |> String.replace_prefix("use ", "") |> String.replace_suffix(";", "")
        [{"depends_on", path, path_name}] ++ traverse_children(node, path, stack)
      "call_expression" ->
        case find_scoped_call(node) do
          nil -> traverse_children(node, path, stack)
          name -> [{"calls", path, name}] ++ traverse_children(node, path, stack)
        end
      _ -> traverse_children(node, path, stack)
    end
  end

  # --- C++ Extraction ---
  defp extract_cpp(node, path, stack) do
    case node[:node_type] do
      "function_definition" ->
        declarator = find_child_node(node, "function_declarator")
        name = find_deep_identifier(declarator)
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "class_specifier" ->
        name = find_child_content(node, "type_identifier")
        [{"defines", path, full_name(stack, name)}] ++ traverse_children(node, path, stack ++ [name])
      "preproc_include" ->
        name = find_child_content(node, "string_literal") || find_child_content(node, "system_lib_string")
        [{"depends_on", path, name}] ++ traverse_children(node, path, stack)
      "call_expression" ->
        traverse_children(node, path, stack)
      _ -> traverse_children(node, path, stack)
    end
  end

  defp full_name([], name), do: name
  defp full_name(stack, name), do: Enum.join(stack ++ [name], ".")

  defp traverse_children(node, path, stack) do
    Enum.flat_map(node[:children] || [], &extract_relationships(&1, path, stack))
  end

  # --- Shared Helpers ---

  defp find_child_content(node, type) do
    (node[:children] || [])
    |> Enum.find(&(&1[:node_type] == type))
    |> case do
      nil -> nil
      child -> child[:content]
    end
  end

  defp find_child_node(node, type) do
    (node[:children] || [])
    |> Enum.find(&(&1[:node_type] == type))
  end

  defp find_deep_identifier(nil), do: "unknown"
  defp find_deep_identifier(node) do
    find_child_content(node, "identifier") || 
    Enum.find_value(node[:children] || [], &find_deep_identifier/1) || 
    "unknown"
  end

  def find_all_nodes_by_type(node, type) do
    current = if node[:node_type] == type, do: [node], else: []
    children = (node[:children] || [])
    |> Enum.flat_map(&find_all_nodes_by_type(&1, type))
    current ++ children
  end

  defp find_all_children_content(node, type) do
    (node[:children] || [])
    |> Enum.filter(&(&1[:node_type] == type))
    |> Enum.map(& &1[:content])
  end

  defp find_attribute_call(node) do
    # os.path.join(...) -> function is attribute
    Enum.find(node[:children] || [], &(&1[:node_type] == "attribute"))
    |> case do
      nil -> nil
      attr -> 
         case String.split(attr[:content], ".") do
           [_] -> nil
           parts -> Enum.drop(parts, -1) |> Enum.join(".")
         end
    end
  end

  defp find_member_call(node) do
    # console.log(...) -> member_expression
    Enum.find(node[:children] || [], &(&1[:node_type] == "member_expression"))
    |> case do
      nil -> nil
      mem ->
         case String.split(mem[:content], ".") do
           [_] -> nil
           parts -> Enum.drop(parts, -1) |> Enum.join(".")
         end
    end
  end

  defp find_selector_call(node) do
    # fmt.Println(...) -> selector_expression
    Enum.find(node[:children] || [], &(&1[:node_type] == "selector_expression"))
    |> case do
      nil -> nil
      sel ->
         case String.split(sel[:content], ".") do
           [_] -> nil
           parts -> Enum.drop(parts, -1) |> Enum.join(".")
         end
    end
  end

  defp find_scoped_call(node) do
    # std::io::println(...) -> scoped_identifier
    Enum.find(node[:children] || [], &(&1[:node_type] == "scoped_identifier"))
    |> case do
      nil -> nil
      scoped ->
         case String.split(scoped[:content], "::") do
           [_] -> nil
           parts -> Enum.drop(parts, -1) |> Enum.join(".")
         end
    end
  end

  defp is_defmodule_call?(node) do
    case node[:children] do
      [%{content: "defmodule", node_type: "identifier"} | _] -> true
      _ -> false
    end
  end

  defp is_dependency_call?(node) do
    case node[:children] do
      [%{content: cmd, node_type: "identifier"} | _] when cmd in ["alias", "import", "require", "use"] -> true
      _ -> false
    end
  end

  defp is_module_call?(node) do
    case node[:children] do
      [%{node_type: "dot"} | _] -> true
      _ -> false
    end
  end

  defp find_all_aliases_in_call(node) do
    direct_aliases =
      (node[:children] || [])
      |> Enum.filter(&(&1[:node_type] in ["alias", "dot"]))
      |> Enum.map(& &1[:content])

    arg_aliases =
      (node[:children] || [])
      |> Enum.filter(&(&1[:node_type] == "arguments"))
      |> Enum.flat_map(fn arg_node ->
        (arg_node[:children] || [])
        |> Enum.filter(&(&1[:node_type] in ["alias", "dot"]))
        |> Enum.map(& &1[:content])
      end)

    direct_aliases ++ arg_aliases
  end

  defp find_module_in_dot_call(node) do
    case node[:children] do
      [%{node_type: "dot", content: content} | _] ->
        # For dot nodes (e.g. ProCoder.Repo.query), the part before the last segment is the module
        case String.split(content, ".") do
          [_] -> nil # local call
          parts -> Enum.drop(parts, -1) |> Enum.join(".")
        end
      _ -> nil
    end
  end

  defp find_module_name_in_call(node) do
    # Handle both parenthesized (in arguments) and unparenthesized (direct child) aliases/dots
    target_node =
      Enum.find(node[:children] || [], &(&1[:node_type] in ["alias", "dot"])) ||
      (Enum.find(node[:children] || [], &(&1[:node_type] == "arguments")) || %{})
      |> Map.get(:children, [])
      |> Enum.find(&(&1[:node_type] in ["alias", "dot"]))

    case target_node do
      %{content: name} -> name
      _ -> "UnknownModule"
    end
  end

  @doc """
  Heuristic to determine the language of a file based on its path.
  """
  def language_from_path(path) do
    ext = Path.extname(path) |> String.downcase()
    case ext do
      ext when ext in [".ex", ".exs"] -> :elixir
      ext when ext in [".js", ".jsx"] -> :javascript
      ext when ext in [".ts", ".tsx"] -> :typescript
      ext when ext in [".py", ".pyw"] -> :python
      ext when ext in [".c", ".h"] -> :c
      ext when ext in [".cpp", ".cc", ".hpp"] -> :cpp
      ".rb" -> :ruby
      ".java" -> :java
      ".go" -> :go
      ".rs" -> :rust
      ".php" -> :php
      ".cs" -> :csharp
      ".swift" -> :swift
      ".kt" -> :kotlin
      ".scala" -> :scala
      ".lua" -> :lua
      ext when ext in [".sh", ".bash", ".zsh"] -> :bash
      ".sql" -> :sql
      ".html" -> :html
      ".css" -> :css
      ".json" -> :json
      ".yaml" -> :yaml
      ".yml" -> :yaml
      ".xml" -> :xml
      ".pl" -> :perl
      ".r" -> :r
      ".hs" -> :haskell
      ".erl" -> :erlang
      ext when ext in [".m", ".mm", ".h"] -> :objective_c
      ".clj" -> :clojure
      ".dockerfile" -> :dockerfile
      "dockerfile" -> :dockerfile
      ".make" -> :makefile
      "makefile" -> :makefile
      ".md" -> :markdown
      ".groovy" -> :groovy
      ".tf" -> :terraform
      ".proto" -> :protobuf
      ".dart" -> :dart
      ".graphql" -> :graphql
      ".zig" -> :zig
      ".jl" -> :julia
      ".toml" -> :toml
      ".vue" -> :vue
      ".svelte" -> :svelte
      ".ps1" -> :powershell
      _ -> :code
    end
  end

  @doc """
  Rigorous fallback extraction for languages without NIF support.
  """
  def extract_rigorous_fallback(lang, content, path) do
    case lang do
      :ruby -> extract_ruby_rigorous(content, path)
      :swift -> extract_swift_rigorous(content, path)
      :kotlin -> extract_kotlin_rigorous(content, path)
      :scala -> extract_scala_rigorous(content, path)
      :lua -> extract_lua_rigorous(content, path)
      :sql -> extract_sql_rigorous(content, path)
      :html -> extract_html_rigorous(content, path)
      :css -> extract_css_rigorous(content, path)
      :json -> extract_json_rigorous(content, path)
      :yaml -> extract_yaml_rigorous(content, path)
      :perl -> extract_perl_rigorous(content, path)
      :r -> extract_r_rigorous(content, path)
      :haskell -> extract_haskell_rigorous(content, path)
      :erlang -> extract_erlang_rigorous(content, path)
      :objective_c -> extract_objc_rigorous(content, path)
      :clojure -> extract_clojure_rigorous(content, path)
      :dockerfile -> extract_docker_rigorous(content, path)
      :makefile -> extract_make_rigorous(content, path)
      :markdown -> extract_md_rigorous(content, path)
      :groovy -> extract_groovy_rigorous(content, path)
      :terraform -> extract_tf_rigorous(content, path)
      :protobuf -> extract_proto_rigorous(content, path)
      :dart -> extract_dart_rigorous(content, path)
      :graphql -> extract_gql_rigorous(content, path)
      :zig -> extract_zig_rigorous(content, path)
      :julia -> extract_julia_rigorous(content, path)
      :toml -> extract_toml_rigorous(content, path)
      :vue -> extract_vue_rigorous(content, path)
      :svelte -> extract_svelte_rigorous(content, path)
      :powershell -> extract_ps_rigorous(content, path)
      _ -> []
    end
  end

  defp extract_tf_rigorous(content, path) do
    # Resources: resource "aws_instance" "web"
    resources = Regex.scan(~r/resource\s+"([a-zA-Z0-9_]+)"\s+"([a-zA-Z0-9_]+)"/i, content)
                |> Enum.map(fn [_, type, name] -> {"defines", path, "#{type}.#{name}"} end)
    # Modules: module "vpc" { source = "./modules/vpc" }
    modules = Regex.scan(~r/module\s+"([a-zA-Z0-9_]+)"\s*\{.*?source\s*=\s*"([^"]+)"/s, content)
              |> Enum.map(fn [_, name, src] -> {"depends_on", path, "#{name}:#{src}"} end)
    # Data: data "aws_ami" "ubuntu"
    data = Regex.scan(~r/data\s+"([a-zA-Z0-9_]+)"\s+"([a-zA-Z0-9_]+)"/i, content)
           |> Enum.map(fn [_, type, name] -> {"depends_on", path, "data.#{type}.#{name}"} end)
    Enum.uniq(resources ++ modules ++ data)
  end

  defp extract_proto_rigorous(content, path) do
    services = Regex.scan(~r/service\s+([a-zA-Z0-9_]+)/, content) |> Enum.map(fn [_, n] -> {"defines", path, n} end)
    messages = Regex.scan(~r/message\s+([a-zA-Z0-9_]+)/, content) |> Enum.map(fn [_, n] -> {"defines", path, n} end)
    imports = Regex.scan(~r/import\s+["'](.*?)["']/, content) |> Enum.map(fn [_, src] -> {"depends_on", path, src} end)
    services ++ messages ++ imports
  end

  defp extract_dart_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:class|abstract\s+class|mixin|extension|void|enum)\s+([a-zA-Z0-9_]+)/m, content) |> Enum.map(fn [_, n] -> {"defines", path, n} end)
    imports = Regex.scan(~r/import\s+['"](.*?)['"]/, content) |> Enum.map(fn [_, src] -> {"depends_on", path, src} end)
    defines ++ imports
  end

  defp extract_gql_rigorous(content, path) do
    defines = Regex.scan(~r/(?:type|interface|enum|input|union|scalar|directive)\s+([a-zA-Z0-9_]+)/, content) |> Enum.map(fn [_, n] -> {"defines", path, n} end)
    fragments = Regex.scan(~r/fragment\s+([a-zA-Z0-9_]+)\s+on/i, content) |> Enum.map(fn [_, n] -> {"defines", path, n} end)
    Enum.uniq(defines ++ fragments)
  end

  defp extract_zig_rigorous(content, path) do
    defines = Regex.scan(~r/pub\s+(?:fn|const|struct|enum|union)\s+([a-zA-Z0-9_]+)/, content) |> Enum.map(fn [_, n] -> {"defines", path, n} end)
    imports = Regex.scan(~r/@import\s*\(\s*["'](.*?)["']\s*\)/, content) |> Enum.map(fn [_, src] -> {"depends_on", path, src} end)
    defines ++ imports
  end

  defp extract_julia_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:module|struct|abstract\s+type|function)\s+([a-zA-Z0-9_!]+)/m, content) |> Enum.map(fn [_, n] -> {"defines", path, n} end)
    imports = Regex.scan(~r/(?:using|import)\s+([a-zA-Z0-9_\.]+)/, content) |> Enum.map(fn [_, n] -> {"depends_on", path, n} end)
    defines ++ imports
  end

  defp extract_toml_rigorous(content, path) do
    # similar to JSON/YAML config links
    Regex.scan(~r/(?:path|source|git|package|file)\s*=\s*['"]?([^'"]+)['"]?/i, content)
    |> Enum.map(fn [_, val] -> {"depends_on", path, val} end)
  end

  defp extract_vue_rigorous(content, path) do
    # Extract from script block
    script = case Regex.run(~r/<script.*?>\s*(.*?)\s*<\/script>/s, content) do
      [_, s] -> s
      _ -> ""
    end
    # capture JS-style imports
    imports = Regex.scan(~r/import\s+.*?\s+from\s+['"](.*?)['"]/m, script) |> Enum.map(fn [_, src] -> {"depends_on", path, src} end)
    # capture components definition
    components = Regex.scan(~r/components\s*:\s*\{([^}]+)\}/s, script) 
                 |> Enum.flat_map(fn [_, body] -> 
                    body |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.filter(&(&1 != ""))
                 end)
                 |> Enum.map(fn name -> {"calls", path, name} end)
    Enum.uniq(imports ++ components)
  end

  defp extract_svelte_rigorous(content, path) do
    script = case Regex.run(~r/<script.*?>\s*(.*?)\s*<\/script>/s, content) do
      [_, s] -> s
      _ -> ""
    end
    imports = Regex.scan(~r/import\s+.*?\s+from\s+['"](.*?)['"]/m, script) |> Enum.map(fn [_, src] -> {"depends_on", path, src} end)
    Enum.uniq(imports)
  end

  defp extract_ps_rigorous(content, path) do
    defines = Regex.scan(~r/function\s+([a-zA-Z0-9_-]+)/i, content) |> Enum.map(fn [_, n] -> {"defines", path, n} end)
    dots = Regex.scan(~r/^\s*\.\s+["']?([^"']+)["']?/m, content) |> Enum.map(fn [_, src] -> {"depends_on", path, src} end)
    defines ++ dots
  end

  defp extract_ruby_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:class|module|def)\s+([a-zA-Z0-9_:]+)/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/^\s*(?:require|load)\s+['"]?([a-zA-Z0-9_\/\.]+)/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    calls   = Regex.scan(~r/([a-zA-Z0-9_]+)\.new/m, content) |> Enum.map(fn [_, name] -> {"calls", path, name} end)
    defines ++ imports ++ calls
  end

  defp extract_swift_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:class|struct|enum|protocol|func|extension)\s+([a-zA-Z0-9_]+)/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/^\s*import\s+([a-zA-Z0-9_]+)/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_kotlin_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:class|interface|object|fun)\s+([a-zA-Z0-9_]+)/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/^\s*import\s+([a-zA-Z0-9_\.]+)/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_scala_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:class|object|trait|def)\s+([a-zA-Z0-9_]+)/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/^\s*import\s+([a-zA-Z0-9_\.]+)/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_lua_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:local\s+)?function\s+([a-zA-Z0-9_\.]+)/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/(?:require|dofile)\s*\(?['"]([a-zA-Z0-9_\/\.]+)['"]\)?/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_sql_rigorous(content, path) do
    tables = Regex.scan(~r/(?:FROM|JOIN|UPDATE|INTO|TABLE)\s+([a-zA-Z0-9_"\.]+)/i, content) 
             |> Enum.map(fn [_, name] -> {"depends_on", path, String.replace(name, "\"", "")} end)
    defines = Regex.scan(~r/CREATE\s+(?:TABLE|VIEW|FUNCTION|PROCEDURE)\s+([a-zA-Z0-9_"\.]+)/i, content)
              |> Enum.map(fn [_, name] -> {"defines", path, String.replace(name, "\"", "")} end)
    Enum.uniq(tables ++ defines)
  end

  defp extract_html_rigorous(content, path) do
    scripts = Regex.scan(~r/<script.*?src=["'](.*?)["']/i, content) |> Enum.map(fn [_, src] -> {"depends_on", path, src} end)
    links = Regex.scan(~r/<link.*?href=["'](.*?)["']/i, content) |> Enum.map(fn [_, href] -> {"depends_on", path, href} end)
    anchors = Regex.scan(~r/<a.*?href=["'](.*?)["']/i, content) 
              |> Enum.map(fn [_, href] -> href end)
              |> Enum.filter(&(!String.starts_with?(&1, ["http", "mailto", "#"])))
              |> Enum.map(fn href -> {"depends_on", path, href} end)
    Enum.uniq(scripts ++ links ++ anchors)
  end

  defp extract_css_rigorous(content, path) do
    imports = Regex.scan(~r/@import\s+(?:url\()?['"]?(.*?)['"]?\)?;/i, content) |> Enum.map(fn [_, src] -> {"depends_on", path, src} end)
    imports
  end

  defp extract_json_rigorous(content, path) do
    Regex.scan(~r/"(?:extends|ref|source|path|main|module)":\s*"([^"]+)"/i, content)
    |> Enum.map(fn [_, val] -> {"depends_on", path, val} end)
  end

  defp extract_yaml_rigorous(content, path) do
    Regex.scan(~r/(?:extends|ref|source|path|file):\s*['"]?([^'"]+)['"]?/i, content)
    |> Enum.map(fn [_, val] -> {"depends_on", path, val} end)
  end

  defp extract_perl_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:package|sub)\s+([a-zA-Z0-9_:]+)/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/^\s*(?:use|require)\s+([a-zA-Z0-9_:]+)/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_r_rigorous(content, path) do
    defines = Regex.scan(~r/([a-zA-Z0-9_\.]+)\s*(?:<-|=)\s*function/i, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/(?:library|require|source)\s*\(?['"]?([a-zA-Z0-9_\/\.]+)['"]?\)?/i, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_haskell_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:module|data|type|newtype)\s+([a-zA-Z0-9_]+)/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/^\s*import\s+(?:qualified\s+)?([a-zA-Z0-9_\.]+)/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_erlang_rigorous(content, path) do
    defines = Regex.scan(~r/^-module\(([a-z0-9_]+)\)\./m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/^-(?:include|include_lib|import)\(["']?(.*?)["']?\)\./m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_objc_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*@(?:interface|implementation|protocol)\s+([a-zA-Z0-9_]+)/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/^\s*#(?:import|include)\s+["'](.*?)["']/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_clojure_rigorous(content, path) do
    defines = Regex.scan(~r/\((?:ns|defn|def)\s+([a-zA-Z0-9_\-\.]+)/, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/(?::require|use)\s+\[?([a-zA-Z0-9_\-\.]+)/, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end

  defp extract_docker_rigorous(content, path) do
    base = Regex.scan(~r/^FROM\s+([a-zA-Z0-9_\/\.:-]+)/mi, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    copies = Regex.scan(~r/^COPY\s+(?:--from=[^\s]+\s+)?([^\s]+)/mi, content) |> Enum.map(fn [_, src] -> {"depends_on", path, src} end)
    Enum.uniq(base ++ copies)
  end

  defp extract_make_rigorous(content, path) do
    includes = Regex.scan(~r/^-?include\s+([a-zA-Z0-9_\/\.\*]+)/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    targets = Regex.scan(~r/^([a-zA-Z0-9_\/\.-]+)\s*:/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    Enum.uniq(includes ++ targets)
  end

  defp extract_md_rigorous(content, path) do
    links = Regex.scan(~r/\[.*?\]\((.*?)[\s\)]/i, content)
            |> Enum.map(fn [_, href] -> href end)
            |> Enum.filter(&(!String.starts_with?(&1, ["http", "mailto", "#"])))
            |> Enum.map(fn href -> {"depends_on", path, href} end)
    Enum.uniq(links)
  end

  defp extract_groovy_rigorous(content, path) do
    defines = Regex.scan(~r/^\s*(?:class|interface|def|enum)\s+([a-zA-Z0-9_]+)/m, content) |> Enum.map(fn [_, name] -> {"defines", path, name} end)
    imports = Regex.scan(~r/^\s*import\s+([a-zA-Z0-9_\.]+)/m, content) |> Enum.map(fn [_, name] -> {"depends_on", path, name} end)
    defines ++ imports
  end
end
