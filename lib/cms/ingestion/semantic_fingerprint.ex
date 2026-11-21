defmodule CMS.Ingestion.SemanticFingerprint do
  @moduledoc """
  Builds a compact, high-signal Semantic Fingerprint for vectorization.

  Replaces the raw source dump previously fed to the embedding model.
  The fingerprint always fits within the 512-token budget of all-MiniLM-L6-v2,
  contains zero syntactic noise, and encodes the six semantic signals that
  define what a file IS, DOES, USES, CALLS, and BELONGS TO.

  ## Fingerprint Structure

      MODULE:  {primary identity — module/class name or basename}
      INTENT:  {purpose — inferred via 5-level cascade if no docstring}
      DEFINES: {public function/class/type names — capability map}
      IMPORTS: {dependency names — relationship context}
      CALLS:   {call targets — runtime behavior graph}
      DOMAIN:  {top-5 non-syntactic keywords — vocabulary}

  ## Intent Inference Cascade (applied when no explicit doc exists)

    Level 1 — Explicit:      @moduledoc / docstring / block comment at file head
    Level 2 — Module name:   module/class/package name parsed from content
    Level 3 — Function API:  first N public function names joined as a phrase
    Level 4 — Import domain: dependency names stripped of namespaces
    Level 5 — Filename:      humanised basename (underscores → spaces)
  """

  alias CMS.Ingestion.CodeGraphEngine

  # Syntactic noise words to strip from keyword extraction.
  # These are the most frequent tokens in source code that carry zero semantic signal.
  @noise_words ~w(
    do end def defp defmodule defprotocol defimpl defstruct use alias import require
    fn if else case when true false nil and or not in is let var const let function
    return self this class new void int bool string float double long byte char type
    module struct enum interface trait object extends implements override pub priv
    begin rescue raise ensure with for while loop break continue yield async await
    from import export default pass lambda match ok error none some just
  ) |> MapSet.new()

  @doc """
  Builds the fingerprint string for a given file.

  ## Parameters
    - `path`          : absolute file path
    - `content`       : raw file content (string)
    - `relationships` : list of `{type, path, name}` tuples from CodeGraphEngine

  ## Returns
    A compact string ready to be fed to the embedding model.
  """
  @spec build(String.t(), String.t(), list()) :: String.t()
  def build(path, content, relationships) do
    lang = CodeGraphEngine.language_from_path(path)

    module_name = extract_module_name(path, content, lang)
    intent      = infer_intent(path, content, lang, relationships)
    defines     = extract_defines(relationships)
    imports     = extract_imports(relationships)
    calls       = extract_calls(relationships)
    domain      = extract_domain_keywords(content, relationships)

    """
    MODULE: #{module_name}
    INTENT: #{intent}
    DEFINES: #{render_list(defines, 20)}
    IMPORTS: #{render_list(imports, 15)}
    CALLS: #{render_list(calls, 15)}
    DOMAIN: #{render_list(domain, 5)}
    """
    |> String.trim()
  end

  # ---------------------------------------------------------------------------
  # Signal 1: Module / Class Name
  # ---------------------------------------------------------------------------

  defp extract_module_name(path, content, lang) do
    # Try to find an explicit module/class declaration first
    explicit = case lang do
      :elixir ->
        case Regex.run(~r/defmodule\s+([a-zA-Z0-9_.]+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      lang when lang in [:python, :ruby, :kotlin, :scala, :groovy] ->
        case Regex.run(~r/^class\s+([a-zA-Z0-9_]+)/m, content) do
          [_, name] -> name
          _ -> nil
        end

      lang when lang in [:java, :csharp] ->
        case Regex.run(~r/(?:public\s+)?(?:class|interface|enum)\s+([a-zA-Z0-9_]+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      :go ->
        case Regex.run(~r/^package\s+([a-zA-Z0-9_]+)/m, content) do
          [_, name] -> name
          _ -> nil
        end

      :rust ->
        case Regex.run(~r/(?:pub\s+)?(?:struct|enum|trait|mod)\s+([a-zA-Z0-9_]+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      :javascript ->
        case Regex.run(~r/(?:class|function)\s+([a-zA-Z0-9_]+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      :typescript ->
        case Regex.run(~r/(?:export\s+)?(?:class|interface|type|function)\s+([a-zA-Z0-9_]+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      :php ->
        case Regex.run(~r/(?:class|interface|trait)\s+([a-zA-Z0-9_]+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      :haskell ->
        case Regex.run(~r/^module\s+([a-zA-Z0-9_.]+)/m, content) do
          [_, name] -> name
          _ -> nil
        end

      :erlang ->
        case Regex.run(~r/^-module\(([a-z0-9_]+)\)\./m, content) do
          [_, name] -> name
          _ -> nil
        end

      :clojure ->
        case Regex.run(~r/\(ns\s+([a-zA-Z0-9_.\-]+)/, content) do
          [_, name] -> name
          _ -> nil
        end

      _ -> nil
    end

    # Level 5 fallback: humanise the filename
    explicit || humanise_basename(path)
  end

  # ---------------------------------------------------------------------------
  # Signal 2: Intent — 5-Level Inference Cascade
  # ---------------------------------------------------------------------------

  defp infer_intent(path, content, lang, relationships) do
    level1(path, content, lang) ||
    level2(content, lang)       ||
    level3(relationships)       ||
    level4(relationships)       ||
    level5(path)
  end

  # Level 1 — Explicit documentation
  defp level1(path, content, lang) do
    ext = Path.extname(path) |> String.downcase()
    result = case lang do
      :elixir ->
        # @moduledoc """..."""
        Regex.run(~r/@moduledoc\s+"""\s*(.*?)\s*"""/s, content)
        |> case do
          [_, doc] -> clean(doc)
          _ ->
            # @moduledoc "..."
            Regex.run(~r/@moduledoc\s+"([^"]+)"/, content)
            |> case do
              [_, doc] -> clean(doc)
              _ -> nil
            end
        end

      :python ->
        # Triple-quoted docstring at module or first class/function level
        Regex.run(~r/^(?:(?:class|def)\s+\w+[^:]*:\s*)?['"]{3}\s*(.*?)\s*['"]{3}/s, content)
        |> case do
          [_, doc] -> clean(doc)
          _ -> nil
        end

      lang when lang in [:javascript, :typescript] ->
        # JSDoc /** ... */ at the top
        Regex.run(~r{/\*\*\s*(.*?)\s*\*/}s, content)
        |> case do
          [_, doc] -> doc |> String.split("\n") |> Enum.map(&String.trim/1)
                         |> Enum.map(&String.trim_leading(&1, "* "))
                         |> Enum.reject(&(&1 == "" or &1 == "*"))
                         |> Enum.join(" ") |> String.trim()
                         |> case do "" -> nil; s -> s end
          _ -> nil
        end

      lang when lang in [:java, :csharp, :go, :cpp, :rust] ->
        # Block comment at the very top: /* ... */ or // leading block
        Regex.run(~r{^/\*[*!]?\s*(.*?)\s*\*/}s, content)
        |> case do
          [_, doc] -> clean(doc)
          _ ->
            # Contiguous // comment block at top
            extract_leading_line_comment(content, "//")
        end

      _ ->
        # Markdown H1 title is the intent
        if ext == ".md" do
          Regex.run(~r/^#\s+(.+)$/m, content)
          |> case do
            [_, title] -> title
            _ -> nil
          end
        else
          # Generic: try leading block comment per language
          leading_block_comment(content, lang)
        end
    end

    case result do
      s when is_binary(s) and byte_size(s) > 8 -> s
      _ -> nil
    end
  end

  # Levels 2–5: Structural inference cascade.

    defp level2(content, lang) do
      pattern = case lang do
        :elixir     -> ~r/defmodule\s+([a-zA-Z0-9_.]+)/
        lang when lang in [:python, :ruby, :kotlin, :scala]
                    -> ~r/^class\s+([a-zA-Z0-9_]+)/m
        lang when lang in [:java, :csharp]
                    -> ~r/(?:public\s+)?(?:class|interface)\s+([a-zA-Z0-9_]+)/
        :go         -> ~r/^package\s+([a-zA-Z0-9_]+)/m
        :rust       -> ~r/(?:pub\s+)?(?:struct|enum|trait)\s+([a-zA-Z0-9_]+)/
        _           -> nil
      end

      with regex when regex != nil <- pattern,
           [_, name] <- Regex.run(regex, content) do
        expand_identifier(name)
      else
        _ -> nil
      end
    end

    defp level3(relationships) do
      defines = relationships
      |> Enum.filter(&match?({"defines", _, _}, &1))
      |> Enum.map(fn {_, _, name} -> name end)
      |> Enum.reject(&String.contains?(&1, "."))
      |> Enum.take(5)

      if defines != [] do
        readable = defines |> Enum.map(&expand_identifier/1) |> Enum.join(", ")
        "Provides: #{readable}"
      else
        nil
      end
    end

    defp level4(relationships) do
      domain_words = relationships
      |> Enum.filter(&match?({"depends_on", _, _}, &1))
      |> Enum.map(fn {_, _, name} ->
        name |> String.split(["/", "\\", "."]) |> List.last()
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(5)

      if domain_words != [] do
        "Uses: #{Enum.join(domain_words, ", ")}"
      else
        nil
      end
    end

    defp level5(path) do
      humanise_basename(path)
    end

  # ---------------------------------------------------------------------------
  # Signal 3: Defines (capability map)
  # ---------------------------------------------------------------------------

  defp extract_defines(relationships) do
    relationships
    |> Enum.filter(&match?({"defines", _, _}, &1))
    |> Enum.map(fn {_, _, name} -> name end)
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Signal 4: Imports (relationship context)
  # ---------------------------------------------------------------------------

  defp extract_imports(relationships) do
    relationships
    |> Enum.filter(&match?({"depends_on", _, _}, &1))
    |> Enum.map(fn {_, _, name} ->
      if is_binary(name) do
        # Use only the leaf segment of namespaced imports to reduce token waste
        # "CMS.Ingestion.SemanticBinder" → "SemanticBinder"
        # "./components/Button" → "Button"
        name
        |> String.split(["/", "\\", "."])
        |> List.last()
        |> String.trim()
      else
        nil
      end
    end)
    |> Enum.reject(&(&1 == "" or &1 == nil))
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Signal 5: Calls (runtime behavior graph)
  # ---------------------------------------------------------------------------

  defp extract_calls(relationships) do
    relationships
    |> Enum.filter(&match?({"calls", _, _}, &1))
    |> Enum.map(fn {_, _, name} ->
      if is_binary(name) do
        name |> String.split(["/", "\\", "."]) |> List.last() |> String.trim()
      else
        nil
      end
    end)
    |> Enum.reject(&(&1 == "" or &1 == nil))
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Signal 6: Domain Keywords (top-5 non-syntactic vocabulary)
  # ---------------------------------------------------------------------------

  defp extract_domain_keywords(content, relationships) do
    # 1. Tokens from content (strip punctuation, lowercase, min 4 chars)
    content_tokens = content
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&(String.length(&1) >= 4))
    |> Enum.reject(&MapSet.member?(@noise_words, &1))

    # 2. Tokens from relationship names (these are already high-signal)
    relationship_tokens = relationships
    |> Enum.flat_map(fn {_, _, name} ->
      if is_binary(name) do
        name
        |> String.split(["/", "\\", ".", "_", "-"])
        |> Enum.map(&String.downcase/1)
        |> Enum.filter(&(String.length(&1) >= 4))
      else
        []
      end
    end)
    |> Enum.reject(&MapSet.member?(@noise_words, &1))

    # 3. Frequency-rank and take top 5
    all_tokens = content_tokens ++ relationship_tokens

    frequencies = Enum.reduce(all_tokens, %{}, fn token, acc ->
      Map.update(acc, token, 1, &(&1 + 1))
    end)

    frequencies
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.map(fn {token, _} -> token end)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp render_list([], _limit), do: "none"
  defp render_list(list, limit) do
    list |> Enum.take(limit) |> Enum.join(", ")
  end

  defp clean(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> String.trim()
  end

  # Convert PascalCase or snake_case identifiers to human-readable phrases
  # "CallGraphBinder" → "Call Graph Binder"
  # "call_graph_binder" → "call graph binder"
  defp expand_identifier(name) do
    name
    # snake_case → spaces
    |> String.replace("_", " ")
    # PascalCase → spaces before caps: "CallGraph" → "Call Graph"
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    # Dot-separated namespaces: take only the last segment
    |> String.split(".")
    |> List.last()
    |> String.trim()
  end

  defp humanise_basename(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> expand_identifier()
  end

  defp extract_leading_line_comment(content, prefix) do
    head = String.slice(content, 0, 3000)
    lines = String.split(head, "\n")

    # Skip shebangs
    lines = case lines do
      ["#!" <> _ | rest] -> rest
      _ -> lines
    end

    comment_lines = Enum.take_while(lines, fn line ->
      String.starts_with?(String.trim(line), prefix)
    end)

    if length(comment_lines) >= 1 do
      comment_lines
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.replace_prefix(&1, prefix, ""))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
      |> case do
        "" -> nil
        s  -> s
      end
    else
      nil
    end
  end

  defp leading_block_comment(content, lang) do
    {open, close} = case lang do
      lang when lang in [:ruby, :perl, :r] -> {~r/^=begin/m,   ~r/=end/}
      lang when lang in [:lua]             -> {~r/--\[\[/,      ~r/\]\]/}
      lang when lang in [:html, :xml, :markdown] -> {~r/<!--/,  ~r/-->/}
      lang when lang in [:css, :scss]      -> {~r{/\*},          ~r{\*/}}
      _                                    -> {nil, nil}
    end

    if open && close do
      pattern = "(?s)#{Regex.source(open)}\\s*(.*?)\\s*#{Regex.source(close)}"
      case Regex.run(Regex.compile!(pattern), content) do
        [_, doc] -> clean(doc) |> case do "" -> nil; s -> s end
        _ -> nil
      end
    else
      nil
    end
  end
end
