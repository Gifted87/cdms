defmodule CMS.SalienceEngine do
  @moduledoc """
  Calculates the intrinsic importance (Salience) of a new Memory Node.

  Implements Section 2.4.3: The Weighting Engine.
  High Salience -> High Antenna Gain -> Wider Broadcast.

  FIX 5 IMPLEMENTED: ML Bridge with Heuristic Fallback.
  """

  require Logger

  # Configuration for the local Python Bridge (e.g., LLM or BERT-based classifier)
  @bridge_url "http://localhost:5000/api/v1/salience"
  @default_timeout 2_000 # 2 seconds - Fail fast to keep ingestion speed high

  # Keywords that imply high criticality (Fallback Logic)
  @critical_keywords ~w(error crash panic critical security breach alert fail exception timeout deadlock)
  @warning_keywords ~w(warning retry slow deprecated latency)

  @doc """
  Calculates a score (0.0 to 1.0) based on content analysis and context.
  It attempts to use the ML Bridge first; otherwise, it falls back to heuristics.
  """
  @spec calculate(String.t(), map()) :: float()
  def calculate(fact_text, provenance_metadata) do
    # 1. Attempt External Semantic Analysis (Fix 5)
    case call_ml_bridge(fact_text, provenance_metadata) do
      {:ok, score} ->
        score

      {:error, _reason} ->
        # 2. Fallback to Heuristic Analysis
        calculate_heuristic(fact_text, provenance_metadata)
    end
  end

  # --- Internal: ML Bridge ---

  defp call_ml_bridge(text, metadata) do
    payload = %{
      text: text,
      provenance: metadata
    }

    try do
      # Requires 'req' library, similar to Tool.Embedder
      case Req.post(@bridge_url, json: payload, receive_timeout: @default_timeout) do
        {:ok, %Req.Response{status: 200, body: %{"score" => score}}} when is_number(score) ->
          # Clamp score between 0.0 and 1.0 just in case
          safe_score = max(0.0, min(1.0, score))
          {:ok, safe_score}

        {:ok, %Req.Response{status: code}} ->
          Logger.warning("Salience Bridge returned non-200 status: #{code}. Switching to heuristic.")
          {:error, :bridge_error}

        {:error, exception} ->
          Logger.warning("Salience Bridge connection failed: #{inspect(exception)}. Switching to heuristic.")
          {:error, :connection_failed}
      end
    rescue
      e ->
        Logger.error("Salience Bridge crashed: #{inspect(e)}")
        {:error, :crash}
    end
  end

  # --- Internal: Heuristic Fallback ---

  defp calculate_heuristic(fact_text, provenance_metadata) do
    base_score = 0.5 # Neutral baseline

    # 1. Contextual Boost (from Provenance)
    # If the agent explicitly flags this as high priority
    context_score = case Map.get(provenance_metadata, "priority", "normal") do
      "critical" -> 1.0
      "high" -> 0.8
      "low" -> 0.2
      _ -> 0.0
    end

    # 2. Content Analysis
    text = String.downcase(fact_text)

    content_score = cond do
      contains_any?(text, @critical_keywords) -> 0.9
      contains_any?(text, @warning_keywords) -> 0.7
      true -> 0.0
    end

    # 3. Maximize
    # If it's explicitly critical OR implicitly critical, we take the max
    max(base_score, max(context_score, content_score))
  end

  defp contains_any?(text, keywords) do
    Enum.any?(keywords, fn k -> String.contains?(text, k) end)
  end
end
