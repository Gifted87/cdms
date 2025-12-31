defmodule CMS.Ingestion.DeterministicAggregator do
  @moduledoc """
  The Deterministic Aggregator: Gathers hard technical facts to build a 
  multi-dimensional profile (Summary Blob) of a node without LLM latency.
  """
  require Logger
  alias CMS.Ingestion.AnatomyEngine

  @language_rules %{
    # C-Style Family (C, C++, C#, Java, JS, TS, Go, Rust, Swift, PHP, Kotlin, Scala)
    c_style: %{
      extensions: ~w(.c .cpp .h .hpp .cs .java .js .ts .jsx .tsx .go .rs .swift .php .kt .scala),
      line_comment: "//",
      block_comment: {~r/\/\*/, ~r/\*\//},
      import_pattern: ~r/^\s*(?:import|using|include|require|package)\s+([a-zA-Z0-9_\.\/"\*-]+)/m,
      function_pattern: ~r/(?:func|fn|function|def|void|int|bool|string|public|private|protected)\s+([a-zA-Z0-9_]+)\s*\(/
    },
    # Scripting Family (Python, Ruby, Perl, Shell, YAML, TOML, Dockerfile, Make)
    script_style: %{
      extensions: ~w(.py .rb .pl .sh .bash .zsh .yaml .yml .toml .dockerfile .make .makefile .conf .properties),
      line_comment: "#",
      block_comment: nil, # Python has docstrings, handled separately or as logic
      import_pattern: ~r/^\s*(?:import|from|require|use|include)\s+([a-zA-Z0-9_\.]+)/m,
      function_pattern: ~r/(?:def|function|func)\s+([a-zA-Z0-9_]+)/
    },
    # Elixir
    elixir_style: %{
      extensions: ~w(.ex .exs),
      line_comment: "#",
      block_comment: nil,
      import_pattern: ~r/^\s*(?:alias|import|require|use)\s+([a-zA-Z0-9_\.]+)/m,
      function_pattern: nil # Handled by AST
    },
    # Erlang
    erlang_style: %{
      extensions: ~w(.erl),
      line_comment: "%%",
      block_comment: nil,
      import_pattern: ~r/^-include\(".*"\)\./m,
      function_pattern: ~r/^([a-z0-9_]+)\s*\(.*\)\s*->/m
    },
    # SQL
    sql_style: %{
      extensions: ~w(.sql),
      line_comment: "--",
      block_comment: {~r/\/\*/, ~r/\*\//},
      import_pattern: nil,
      function_pattern: ~r/(?:CREATE\s+FUNCTION|CREATE\s+PROCEDURE)\s+([a-zA-Z0-9_]+)/i
    },
    # Lisp (Clojure, Scheme)
    lisp_style: %{
      extensions: ~w(.clj .lisp .scm .el),
      line_comment: ";;",
      block_comment: nil,
      import_pattern: ~r/\((?:require|use|import)\s+'?([a-zA-Z0-9\.\/-]+)/,
      function_pattern: ~r/\((?:defn|defun)\s+([a-zA-Z0-9_\-\.]+)/
    },
    # Web Markup (HTML, XML)
    markup_style: %{
      extensions: ~w(.html .xml .svg .xhtml .vue .svelte),
      line_comment: nil,
      block_comment: {~r/<!--/, ~r/-->/},
      import_pattern: ~r/<(?:script|link|import).*?(?:src|href)=["'](.*?)["']/,
      function_pattern: nil
    },
    # Lua
    lua_style: %{
      extensions: ~w(.lua),
      line_comment: "--",
      block_comment: {~r/--\[\[/, ~r/\]\]/},
      import_pattern: ~r/(?:require|dofile)\s*\(?["'](.*?)["']\)?/,
      function_pattern: ~r/function\s+([a-zA-Z0-9_\.]+)/
    },
    # Documentation & Data
    data_doc_style: %{
      extensions: ~w(.md .json .csv .log .out .err),
      line_comment: nil,
      block_comment: nil,
      import_pattern: nil,
      function_pattern: nil
    },
    # Archives
    archive_style: %{
      extensions: ~w(.zip .tar .gz .7z .rar .jar .war .ear .iso),
      line_comment: nil,
      block_comment: nil,
      import_pattern: nil,
      function_pattern: nil,
      is_binary: true
    },
    # Application Packages & Binaries
    package_style: %{
      extensions: ~w(.exe .app .deb .rpm .bin .dll .so .dylib .dmg .msi),
      line_comment: nil,
      block_comment: nil,
      import_pattern: nil,
      function_pattern: nil,
      is_binary: true
    }
  }

  @doc """
  Aggregates seven dimensions of introspection into a standardized Summary Blob.
  """
  def aggregate(path, content, mime) do
    # 1. Identify Logic Rules based on Extension
    ext = Path.extname(path) |> String.downcase()
    rules = get_rules_for_ext(ext)

    intent = get_intent(path, content, rules)
    structure = get_structure(path, content, rules)
    imports = get_imports(content, rules)
    comments = get_all_comments(content, rules)
    keywords = get_keywords(path, content, rules)
    geography = get_geography(path)
    anatomy = get_anatomy(path, mime)

    """
    [INTENT]: #{intent}
    [STRUCTURE]: #{structure}
    [IMPORTS]: #{imports}
    [COMMENTS]: #{comments}
    [KEYWORDS]: #{keywords}
    [GEOGRAPHY]: #{geography}
    [ANATOMY]: #{anatomy}
    """ |> String.trim()
  end

  defp get_rules_for_ext(ext) do
    Enum.find_value(@language_rules, %{}, fn {_style, rules} -> 
      if ext in rules.extensions, do: rules, else: nil
    end)
  end

  # --- Dimension 1: The Declared Intent ---
  defp get_intent(path, content, rules) do
    ext = Path.extname(path) |> String.downcase()
    cond do
      ext in [".ex", ".exs"] ->
         case Regex.run(~r/@moduledoc\s+"""\s*(.*?)\s*"""/s, content) do
          [_, doc] -> clean_doc(doc)
          _ -> "No module documentation found."
        end
      ext == ".py" ->
        case Regex.run(~r/^["']{3}\s*(.*?)\s*["']{3}/s, content) do
          [_, doc] -> clean_doc(doc)
          _ -> "No docstring found."
        end
      ext == ".md" ->
        case Regex.run(~r/^#\s+(.+)$/m, content) do
          [_, title] -> "Documentation Title: #{title}"
          _ -> "Markdown documentation."
        end
      ext in ~w(.log .out .err) ->
        "System log file capturing runtime events."
      true ->
        cond do
          Map.get(rules, :is_binary) ->
             if ext in ~w(.zip .tar .gz .7z .rar .jar .war .ear .iso), do: "Compressed archive artifact.", else: "Executable or distribution package."
          true ->
            # Fallback to first comment block from logic rules
            block_def = Map.get(rules, :block_comment)
            intent_from_block = case block_def do
              {start_regex, end_regex} -> 
                 # We want to match from the VERY FIRST occurrence of start_regex
                 # but only if it's near the top of the file (first 50 lines)
                 # Regex.source extracts the pattern without sigil metadata
                 pattern = "(?s)#{Regex.source(start_regex)}\\s*(.*?)\\s*#{Regex.source(end_regex)}"
                 case Regex.run(Regex.compile!(pattern), content) do
                   [_, doc] -> clean_doc(doc)
                   _ -> nil
                 end
              _ -> nil
            end

            # 2. Fallback to Line Comments
            if intent_from_block do
               intent_from_block
            else
               prefix = Map.get(rules, :line_comment)
               if prefix do
                  extract_continuous_comments(content, prefix)
               else
                  "System file (Binary or Data)."
               end
            end
        end
    end
  end

  defp clean_doc(doc) do
    doc |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.join(" ") |> String.trim()
  end

  defp extract_continuous_comments(content, prefix) do
    # Optimized: Only look at the first 5kb to avoid RAM-bombing on large files
    head = String.slice(content, 0, 5000)
    
    lines = String.split(head, "\n")
    
    # Handle Shebangs (skip if first line starts with #!)
    lines = case lines do
      ["#!" <> _ | rest] -> rest
      _ -> lines
    end

    comments = Enum.take_while(lines, &String.starts_with?(String.trim(&1), prefix))
    
    if comments != [] do
       Enum.map(comments, fn l -> String.trim(l) |> String.replace_prefix(prefix, "") |> String.trim() end)
       |> Enum.filter(&(&1 != "")) |> Enum.join(" ")
    else
      "No header comments found."
    end
  end

  # --- Dimension 2: The Functional Surface [STRUCTURE] ---
  defp get_structure(path, content, rules) do
     ext = Path.extname(path) |> String.downcase()
     cond do
       ext in [".ex", ".exs"] ->
          try do
            case Code.string_to_quoted(content) do
              {:ok, quoted} ->
                {modules, functions} = analyze_elixir_structure(quoted)
                "Module: #{Enum.join(modules, ", ")} | Exports: #{Enum.join(functions, ", ")}"
              _ -> "Structure analysis failed (Syntax Error)."
            end
          rescue
            _ -> "Structure analysis failed (Parser Crash)."
          end
       ext == ".md" ->
          headers = Regex.scan(~R/^#{1,3}\s+(.+)$/m, content) |> Enum.map(&List.last/1)
          "Headers: #{Enum.join(headers, " > ")}"
       ext == ".json" ->
          # Very naive top-level key extraction
          keys = Regex.scan(~r/"([a-zA-Z0-9_-]+)"\s*:/, content) 
                 |> Enum.map(&List.last/1) 
                 |> Enum.uniq() 
                 |> Enum.take(20)
          "JSON Keys: #{Enum.join(keys, ", ")}"
       ext == ".csv" ->
          header_line = String.split(content, "\n") |> List.first() |> String.split(",") |> Enum.map(&String.trim/1)
          "CSV Columns: #{Enum.join(header_line, ", ")}"
       ext in ~w(.log .out .err) ->
          has_errors = String.contains?(String.upcase(content), "ERROR")
          "Log features: #{if has_errors, do: "CONTAINS ERRORS", else: "Clean"}"
       true ->
          cond do
            Map.get(rules, :is_binary) ->
              if ext in ~w(.zip .tar .gz .7z .rar .jar .war .ear .iso), do: "Binary container/Archive.", else: "Binary executable/Deployment artifact."
            true ->
              # Regex-based extraction using rules
              pattern = Map.get(rules, :function_pattern)
              if pattern do
                 funcs = Regex.scan(pattern, content)
                         |> Enum.map(&List.last/1)
                         |> Enum.uniq()
                         |> Enum.take(30)
                 "Functions/Defs: #{Enum.join(funcs, ", ")}"
              else
                 "Structure implicit or undefined."
              end
          end
     end
  end

  defp analyze_elixir_structure(quoted) do
    {_ast, acc} = Macro.prewalk(quoted, {[], []}, fn
      {:defmodule, _, [{:__aliases__, _, names} | _]}, {mods, funs} ->
        {nil, {[Enum.join(names, ".") | mods], funs}}
      {:def, _, [{name, _, args} | _]}, {mods, funs} ->
        {nil, {mods, funs ++ ["#{name}/#{length(args || [])}"]}}
      node, acc -> {node, acc}
    end)
    {Enum.reverse(elem(acc, 0)), Enum.reverse(elem(acc, 1))}
  end

  # --- Dimension 3: [IMPORTS] ---
  defp get_imports(content, rules) do
    if Map.get(rules, :is_binary) do
       "Not applicable to binary artifacts."
    else
      pattern = Map.get(rules, :import_pattern)
      if pattern do
        Regex.scan(pattern, content)
        |> Enum.map(&List.last/1)
        |> Enum.uniq()
        |> Enum.join(", ")
        |> case do
          "" -> "None detected."
          s -> s
        end
      else
        "Import extraction not supported."
      end
    end
  end

  # --- Dimension 4: [COMMENTS] ---
  defp get_all_comments(content, rules) do
    if Map.get(rules, :is_binary) do
       "Not applicable to binary artifacts."
    else
      line_prefix = Map.get(rules, :line_comment)
      block_def = Map.get(rules, :block_comment)

      # 1. Extract Line Comments (Unanchored as per user request: Catch all potential comments)
      line_comments = if line_prefix do
         # Use regex scan instead of String.split to avoid RAM explosion
         # Matches: Anything -> prefix -> capture content
         # We allow false positives (like URLs) to ensure we don't miss inline comments
         pattern = ~r/#{Regex.escape(line_prefix)}(.*)$/m
         Regex.scan(pattern, content)
         |> Enum.map(fn 
              [_, capture] -> String.trim(capture)
              _ -> ""
            end)
         |> Enum.filter(&(&1 != ""))
      else
        []
      end

      # 2. Extract Block Comments
      block_comments = case block_def do
        {start_regex, end_regex} ->
            # robustly scan for all block comments
            pattern = "(?s)#{Regex.source(start_regex)}(.*?)#{Regex.source(end_regex)}"
            case Regex.compile(pattern) do
              {:ok, regex} ->
                Regex.scan(regex, content)
                |> Enum.map(fn match -> 
                     # match is usually [full_match, capture] or just [full_match]
                     List.last(match) |> String.trim()
                   end)
              _ -> []
            end
        _ -> []
      end

      all = line_comments ++ block_comments
      if all == [] do
        "No comments found."
      else
        # Limit size to prevent massive blobs
        Enum.join(all, " -- ") |> String.slice(0, 5000) 
      end
    end
  end

  # --- Dimension 5: Keywords ---
  defp get_keywords(path, content, rules) do
     stop_words = ~w(the a an and or but if then else for each while in of to is as with from which this that these those return import package end do void public class const var let module def fn function string int bool)
     
     source = if Map.get(rules, :is_binary), do: Path.basename(path), else: content

     source
     |> String.split(~r/[^a-zA-Z0-9_]+/, trim: true)
     |> Enum.reduce(%{}, fn token, acc -> score_token(token, acc, stop_words) end)
     |> Enum.sort_by(fn {_word, score} -> score end, :desc)
     |> Enum.take(10) # Expanded to 10
     |> Enum.map(fn {word, _} -> word end)
     |> Enum.join(", ")
  end

  defp score_token(token, acc, stop_words) do
    lower = String.downcase(token)
    if String.length(token) < 3 or Enum.member?(stop_words, lower) or String.match?(token, ~r/^[0-9]+$/) do
      acc
    else
      base_score = Map.get(acc, token, 0)
      additional = 1
      additional = if String.match?(token, ~r/^[A-Z][a-z]+[A-Z]/), do: additional + 2, else: additional
      Map.put(acc, token, base_score + additional)
    end
  end

  # --- Dimension 6: Geography ---
  defp get_geography(path) do
    components = Path.split(path) |> Enum.reverse()
    cond do
      "controllers" in components -> "Web Controller"
      "views" in components -> "Web View"
      "templates" in components -> "UI Template"
      "migrations" in components -> "DB Migration"
      "models" in components -> "Data Model"
      "services" in components -> "Service Layer"
      "test" in components -> "Test Suite"
      true -> "Path: #{Path.dirname(path)}"
    end
  end

  # --- Dimension 7: Biology ---
  defp get_anatomy(path, mime) do
     triage_class = case CMS.Ingestion.TriageProtocol.identify(path) do
       {:ok, c} -> c
       _ -> :unknown
     end
     "OrganType: #{AnatomyEngine.classify_organ(triage_class, path, mime)} | Metabolism: #{AnatomyEngine.classify_metabolism(path, triage_class)}"
  end
end

