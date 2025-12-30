defmodule CREMS.NodeHead do
  @moduledoc """
  The Cognitive Nucleus of a CREMS Node.
  Manages semantic self-representation and the autonomous firing decision.
  """

  defstruct [
    :embedding,          # Nx.Tensor[384] - Compatible with all-MiniLM-L6-v2
    :urgency_threshold,  # Float (0.0 - 1.0)
    :cognitive_state     # Atom: :genesis | :steady | :distressed | :dying
  ]

  @type t :: %__MODULE__{
    embedding: Nx.Tensor.t(),
    urgency_threshold: float(),
    cognitive_state: :genesis | :steady | :distressed | :dying
  }

  @doc """
  Autonomous Firing Decision.
  Decides whether to respond to a system-wide broadcast query.
  
  Logic:
  1. Semantic Match: Cosine Similarity between QueryVector and SelfEmbedding.
  2. Urgency Override: EffectiveThreshold = BaseThreshold * (1.0 - CurrentStress).
  3. Returns TRUE if Sim > EffectiveThreshold.
  """
  def should_fire?(%__MODULE__{} = head, query_vector, current_stress) do
    similarity = calculate_cosine_similarity(head.embedding, query_vector)
    effective_threshold = head.urgency_threshold * (1.0 - current_stress)

    similarity > effective_threshold
  end

  # Helper for Cosine Similarity (Placeholder for CDMS standard math if strictly separate)
  # Ideally checks CMS.Core.Math or similar if available, otherwise implementation here:
  defp calculate_cosine_similarity(vec_a, vec_b) do
    # Assuming Nx is available as per spec mentioning Nx.Tensor
    # Use standard Cosine Similarity: (A . B) / (||A|| * ||B||)
    
    # We will assume vectors are already normalized for optimization as is common in CDMS
    # If not, full calculation:
    Nx.dot(vec_a, vec_b) 
    |> Nx.divide(Nx.multiply(Nx.LinAlg.norm(vec_a), Nx.LinAlg.norm(vec_b)))
    |> Nx.to_number()
  end
end
