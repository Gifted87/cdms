defmodule CREMS.NodeTail do
  @moduledoc """
  The Functional Connectome of a CREMS Node.
  Defines wiring with hierarchical, communication, dependency, and semantic edges.
  """

  defstruct [
    :hierarchical_edges,  # List: {:parent_of | :child_of, target_uuid}
    :communication_edges, # List: {:communicates_with, target_uuid, protocol, transfer_ratio}
    :dependency_edges,    # List: {:depends_on, target_uuid}
    :semantic_edges,      # List: {:semantically_related_to, target_uuid, score}
    :symbiotic_edges      # List: {:defined_by | :defines, target_uuid}
  ]

  @type t :: %__MODULE__{
    hierarchical_edges: list(),
    communication_edges: list(),
    dependency_edges: list(),
    semantic_edges: list(),
    symbiotic_edges: list()
  }
end
