defmodule CMS.NodeHead do
  @moduledoc """
  Represents the 'Head' of a CMS Node: The Local Cognitive Engine.

  Responsibilities:
  1. Holds the semantic vector embedding for similarity comparisons.
  2. Manages the 'Metabolic State' (internal_state) which acts as a firing inhibitor.
  3. Tracks the embedding model version to handle Model Drift (Gap 7).
  """

  # Custom Jason.Encoder implemented below to handle tuple conversion

  defstruct [
    :uuid,                    # 128-bit persistent identifier
    :embedding,               # Nx.Tensor: The semantic representation
    :embedding_model_version, # String: e.g., "openai_ada_002_v1"
    :relevance_threshold,     # Float (0.0 - 1.0)
    :internal_state,          # Enum [Genesis, Steady, Mutating, Dormant]
    :spatial_coords,          # {x, y, z} tuple
    :width_descriptor,        # String: e.g., "mc0" (Gap 6.3)
    :label                    # String: Label for Jaro fallbacks
  ]

  @type uuid :: String.t()
  @type embedding :: Nx.Tensor.t()
  @type model_version :: String.t()
  @type internal_state :: :genesis | :steady | :mutating | :dormant
  @type spatial_coords :: {float(), float(), integer()}
  @type width_descriptor :: String.t()

  @type t :: %__MODULE__{
    uuid: uuid(),
    embedding: embedding(),
    embedding_model_version: model_version(),
    relevance_threshold: float(),
    internal_state: internal_state(),
    spatial_coords: spatial_coords(),
    width_descriptor: width_descriptor()
  }

  @doc """
  Creates a new NodeHead with default metabolic energy.
  Z-Axis in `coords` represents Hierarchical Depth (Root = 0).
  """
  @spec new(String.t(), Nx.Tensor.t(), String.t(), float(), {float(), float(), integer()}, String.t(), String.t()) :: t()
  def new(uuid, embedding, model_version, threshold \\ 0.35, coords \\ {0.0, 0.0, 0}, width \\ "m0", label \\ "") do
    %__MODULE__{
      uuid: uuid,
      embedding: embedding,
      embedding_model_version: model_version,
      relevance_threshold: threshold,
      internal_state: :genesis,
      spatial_coords: coords,
      width_descriptor: width,
      label: label
    }
  end

  # --- JSON Encoding ---
  defimpl Jason.Encoder, for: __MODULE__ do
    def encode(value, opts) do
      # Convert spatial_coords tuple to list for JSON serialization
      {x, y, z} = value.spatial_coords
      
      %{
        uuid: value.uuid,
        embedding: value.embedding,
        embedding_model_version: value.embedding_model_version,
        relevance_threshold: value.relevance_threshold,
        internal_state: value.internal_state,
        spatial_coords: [x, y, z],  # Convert tuple to list
        width_descriptor: value.width_descriptor
      }
      |> Jason.Encode.map(opts)
    end
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
