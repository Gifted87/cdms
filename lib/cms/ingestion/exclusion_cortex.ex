defmodule CMS.Ingestion.ExclusionCortex do
  @moduledoc """
  The Intelligent Exclusion Cortex: Filters out noise and protects against "Cognitive Swamp".
  """

  require Logger

  @default_blocklist ~w(.git .svn node_modules _build target venv __pycache__ deps priv mnesia_store .elixir_ls)
  @max_file_size_bytes 100 * 1024 * 1024 # 100MB

  @doc """
  Gate 1: Explicit Gate (Pattern Matching).
  Decides whether to traverse a directory or drop it.
  """
  def should_traverse?(path) do
    basename = Path.basename(path)
    if Enum.member?(@default_blocklist, basename) do
      Logger.debug("ExclusionCortex: Dropping #{path} (Blocklist)")
      false
    else
      true
    end
  end

  @doc """
  Gate 2: Heuristic Gate (The Noise Filter).
  Decides if a file should be deep processed (Mode A) or shallow indexed (Mode B).
  """
  def assess_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_file_size_bytes ->
        {:ok, :mode_b_shallow, :size_limit}

      {:ok, _stat} ->
        cond do
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

