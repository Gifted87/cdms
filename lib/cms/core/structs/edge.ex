defmodule CMS.Edge do
  @moduledoc """
  Represents an associative or structural link between two CMS Nodes.

  Crucial for defining the cognitive graph's topology.
  Implements Gap B: Explicit Link Typing.
  """

  @derive {Jason.Encoder, only: [:target_node_id, :type, :weight, :last_used_at]}
  defstruct [
    :target_node_id, # String: UUID/Hash of the connected node
    :type,           # Atom: :semantic, :syntactic, :dependency, :contradicts, :causes
    :weight,         # Float 0.01 - 1.0: Hebbian strength.
    :last_used_at    # DateTime: For DecayManager to calculate 'Active Forgetting'
  ]

  @type link_type :: :semantic | :syntactic | :dependency | :contradicts | :causes | :similar_to

  @type t :: %__MODULE__{
    target_node_id: String.t(),
    type: link_type(),
    weight: float(),
    last_used_at: DateTime.t()
  }

  @doc """
  Creates a new edge. Clamps weight between 0.01 and 1.0.
  """
  @spec new(String.t(), link_type(), float()) :: t()
  def new(target_node_id, type, weight \\ 0.5) do
    # Clamp weight to ensure system stability
    safe_weight = max(0.01, min(1.0, weight))

    %__MODULE__{
      target_node_id: target_node_id,
      type: type,
      weight: safe_weight,
      last_used_at: DateTime.utc_now()
    }
  end

  # --- Access Behavior ---
  @behaviour Access

  @impl Access
  def fetch(term, key), do: Map.fetch(term, key)

  @impl Access
  def get_and_update(term, key, fun), do: Map.get_and_update(term, key, fun)

  @impl Access
  def pop(term, key), do: Map.pop(term, key)
end
