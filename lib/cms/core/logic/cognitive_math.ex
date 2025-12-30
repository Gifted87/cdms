defmodule CMS.Core.Logic.CognitiveMath do
  @moduledoc """
  The Shared Mathematical Engine for Cognition.
  
  Used by both CDMS (Static) and CREMS (Runtime) Nodes to ensure
  identical behavior for:
  1. Semantic Relevance (Cosine Similarity)
  2. Spreading Activation (Thresholds & Boosts)
  3. Hebbian Learning (Weight Updates)
  """

  # --- Formula A: Relevance Score ---
  
  @doc """
  Calculates the relevance score ($R$) between a node embedding and a query vector.
  Falls back to Jaro Distance string matching if Nx/Vectors fail.
  """
  def calculate_relevance_score(embedding, query_vector, node_text, query_text) do
    try do
      # Assuming vectors are normalized, dot product is cosine similarity
      Nx.dot(embedding, query_vector) |> Nx.to_number()
    rescue
      _ -> 
        # Fallback: Jaro Distance similarity
        if node_text != "" and query_text != "" do
          String.jaro_distance(node_text, query_text)
        else
          0.0
        end
    end
  end

  # --- Formula B: Adjusted Threshold ---

  @doc """
  Calculates the Adjusted Threshold ($T_{adj}$) based on Global Inhibition.
  Logic: Threshold rises as Global Inhibition (Congestion) drops.
  Target: When Inhibition is 1.0 (Healthy), Threshold is Base.
  """
  def calculate_adjusted_threshold(t_base, i_global, _internal_state) do
    # FIX: When i_global is 1.0 (Healthy), we want the threshold to be t_base (e.g., 0.7).
    # When i_global drops to 0.1 (Congested), the threshold should rise significantly.
    safe_inhibition = max(0.1, i_global)
    t_base / safe_inhibition
  end

  # --- Formula C: Associative Boost ---

  @doc """
  Calculates the Associative Boost ($\Delta A$) for Spreading Activation.
  Combines signal strength (Influence), edge type factor, and context mode.
  """
  def calculate_associative_boost(r_origin_times_weight, _redundant_weight, type, context_mode) do
    f_type = case type do
      :dependency -> 1.0
      :causes -> 0.9
      :relates_to -> 0.8
      :semantic -> 0.8
      :contradicts -> 0.2
      :child_of -> 1.0
      _ -> 0.5
    end

    f_context = case context_mode do
      :brainstorm -> 1.5
      _ -> 1.0
    end

    synaptic_resistance = 0.8

    r_origin_times_weight * f_type * f_context * synaptic_resistance
  end

  # --- Logic D: Hebbian Weight Update ---

  @doc """
  Calculates the new weight for an edge based on a delta.
  Enforces bounds [0.01, 1.0].
  """
  def calculate_new_hebbian_weight(current_weight, delta) do
    min(1.0, max(0.01, current_weight + delta))
  end

  # --- Helpers: Statistics ---

  @doc """
  Performs a simple linear regression on a list of {x, y} points.
  Returns {:ok, %{slope: m, intercept: b}} or {:error, :insufficient_data}.
  """
  def linear_regression(points) when length(points) < 2, do: {:error, :insufficient_data}
  def linear_regression(points) do
    n = length(points)
    {sum_x, sum_y, sum_xx, sum_xy} = Enum.reduce(points, {0.0, 0.0, 0.0, 0.0}, fn {x, y}, {sx, sy, sxx, sxy} ->
      {sx + x, sy + y, sxx + x * x, sxy + x * y}
    end)

    denominator = (n * sum_xx - sum_x * sum_x)

    if abs(denominator) < 1.0e-10 do
      {:error, :vertical_line}
    else
      m = (n * sum_xy - sum_x * sum_y) / denominator
      b = (sum_y - m * sum_x) / n
      {:ok, %{slope: m, intercept: b}}
    end
  end
end
