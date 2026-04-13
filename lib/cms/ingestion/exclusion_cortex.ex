defmodule CMS.Ingestion.ExclusionCortex do
  @moduledoc """
  The Intelligent Exclusion Cortex: Filters out noise and protects against "Cognitive Swamp".
  """

  require Logger

  @default_blocklist ~w(
    .git .svn .hg .bzr CVS
    node_modules bower_components jspm_packages packages
    _build target build dist out bin obj release debug
    venv .venv env __pycache__ .pytest_cache .tox
    .bundle vendor/bundle
    .idea .vscode .settings .project .classpath
    .elixir_ls deps doc docs _site coverage .nyc_output
    tmp temp logs
    .terraform terraform.tfstate.d
    .sass-cache
    mnesia_store memory_cartridges .cdms_model .gemini .procoder .acn .cdms_node_registry.json
    locale locale-archive gconv zoneinfo terminfo
  )
  
  @blocked_extensions ~w(.woff .woff2 .ttf .otf .eot .png .jpg .jpeg .gif .ico .svg .webp .mp4 .webm .ogv .mp3 .wav .flac .zip .tar .gz .rar .7z .pdf .dmg .iso .bin .exe .dll .so .dylib)

  @max_file_size_bytes 100 * 1024 * 1024 # 100MB

  @doc """
  Gate 1: Explicit Gate (Pattern Matching).
  Decides whether to traverse a directory or drop it.
  """
  def should_traverse?(path) do
    root = Application.get_env(:acn_cms, :project_root)
    
    path_components = Path.split(path) |> Enum.map(fn c -> c |> String.trim() |> String.downcase() end)
    ext = Path.extname(path) |> String.downcase()
    
    # Identify which components to actually scrutinize for blocklist patterns.
    # We only care about components that were added TO the root (internal to the project).
    # This allows a project in /tmp/proj to NOT be blocked by the /tmp parent.
    check_components = 
      if root do
        root_components = Path.split(root) |> Enum.map(fn c -> c |> String.trim() |> String.downcase() end)
        
        if List.starts_with?(path_components, root_components) do
           # Internal or exactly root: only check the parts AFTER the root.
           Enum.drop(path_components, length(root_components))
        else
           # Outside of root: check full hierarchy for safety.
           path_components
        end
      else
        # No project root set: check everything.
        path_components
      end

    cond do
      # 1. Check if any RELEVANT path component is explicitly blocklisted
      Enum.any?(check_components, &Enum.member?(@default_blocklist, &1)) ->
        Logger.debug("ExclusionCortex: Dropping #{path} (Blocklist match in project path)")
        false
      
      # 2. Check for blocked extension (Global check)
      Enum.member?(@blocked_extensions, ext) ->
        Logger.debug("ExclusionCortex: Dropping #{path} (Blocked Extension)")
        false

      # 3. Check for hidden items internal to the project
      Enum.any?(check_components, fn 
        "." -> false
        ".." -> false
        comp -> String.starts_with?(comp, ".") and comp not in ~w(.env .gitignore .dockerignore .antigravityignore)
      end) ->
        Logger.debug("ExclusionCortex: Dropping #{path} (Hidden component in project path)")
        false

      true ->
        true
    end
  end

  @doc """
  Gate 2: Heuristic Gate (The Noise Filter).
  Decides if a file should be deep processed (Mode A) or shallow indexed (Mode B).
  """
  def assess_file(path) do
    ext = Path.extname(path) |> String.downcase()

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_file_size_bytes ->
        {:ok, :mode_b_shallow, :size_limit}

      {:ok, _stat} ->
        cond do
          Enum.member?(@blocked_extensions, ext) ->
            {:ok, :mode_b_shallow, :blocked_extension}

          is_binary?(path) ->
            {:ok, :mode_b_shallow, :binary}

          true ->
            # Blood nodes (logs) are now ALLOWED in Mode A for stream monitoring
            {:ok, :mode_a_deep, :cognitive_target}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gate 3: Semantic Gate (The Hallucination Check).
  Checks if the LLM output is coherent and wasn't tripped by minified/obfuscated code.
  """
  def validate_cognition(summary) do
    cond do
      is_nil(summary) or String.length(summary) < 15 ->
        Logger.warning("ExclusionCortex: Semantic Gate FAILURE (Low Confidence) - summary: #{inspect(summary)}")
        {:error, :low_confidence}
      String.match?(summary, ~r/(minified|obfuscated|gibberish|cannot summarize)/i) ->
        Logger.warning("ExclusionCortex: Semantic Gate FAILURE (Obfuscated) - summary: #{inspect(summary)}")
        {:error, :obfuscated}
      true ->
        :ok
    end
  end

  defp is_binary?(path) do
    # Check first 1KB for NULL byte, as per spec Gate 2.
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        chunk = IO.binread(file, 1024)
        File.close(file)
        is_binary(chunk) and :binary.match(chunk, <<0>>) != :nomatch
      _ -> false
    end
  end
end

