defmodule CREMS.NodeTail do
  @moduledoc """
  The Functional Connectome of a CREMS Node.
  Defines wiring with hierarchical, communication, dependency, and semantic edges.
  """

  defstruct [
    :hierarchical_edges,  # List of Maps: %{type: :parent_of | :child_of, target_node_id: uuid, weight: 1.0}
    :communication_edges, # List of Maps: %{type: :communicates_with, target_node_id: uuid, protocol: proto, ratio: score}
    :dependency_edges,    # List of Maps: %{type: :depends_on, target_node_id: uuid, weight: score}
    :semantic_edges,      # List of Maps: %{type: :semantically_related_to, target_node_id: uuid, weight: score}
    :symbiotic_edges      # List of Maps: %{type: :defined_by | :defines, target_node_id: uuid, weight: 1.0}
  ]

  @type t :: %__MODULE__{
    hierarchical_edges: list(),
    communication_edges: list(),
    dependency_edges: list(),
    semantic_edges: list(),
    symbiotic_edges: list()
  }
end
