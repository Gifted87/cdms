defmodule CMS.NodeTail do
  @moduledoc """
  The Connectome: Manages the graph topology and edges for a CDMS Node.
  """

  alias CMS.Edge

  @derive {Jason.Encoder, only: [:hierarchical, :syntactic, :semantic, :functional]}
  defstruct [
    hierarchical: [], # List of CMS.Edge (PARENT_OF, CHILD_OF)
    syntactic: [],    # List of CMS.Edge (IMPORTS, IMPORTED_BY)
    semantic: [],     # List of CMS.Edge (RELATES_TO)
    functional: []    # List of CMS.Edge (Skeletal, Immune, Nervous)
  ]

  @type t :: %__MODULE__{
    hierarchical: [Edge.t()],
    syntactic: [Edge.t()],
    semantic: [Edge.t()],
    functional: [Edge.t()]
  }

  @doc """
  Creates a new empty Connectome.
  """
  def new do
    %__MODULE__{
      hierarchical: [],
      syntactic: [],
      semantic: [],
      functional: []
    }
  end

  @doc """
  Adds an edge to the appropriate category in the connectome.
  Ensures idempotency (no duplicate target/type pairs).
  """
  def add_edge(tail, %Edge{target_node_id: target, type: type} = edge) do
    case type do
      t when t in [:parent_of, :child_of] ->
        if exists?(tail.hierarchical, target, t), do: tail, else: %{tail | hierarchical: [edge | tail.hierarchical]}

      t when t in [:imports, :imported_by] ->
        if exists?(tail.syntactic, target, t), do: tail, else: %{tail | syntactic: [edge | tail.syntactic]}

      t when t in [:relates_to, :semantic, :contradicts, :supersedes, :superseded_by] ->
        if exists?(tail.semantic, target, t), do: tail, else: %{tail | semantic: [edge | tail.semantic]}

      t when t in [:links_dynamically_to, :symlinks_to, :mounts_on, :owned_by, :executable_by, :configures, :logs_to] ->
        if exists?(tail.functional, target, t), do: tail, else: %{tail | functional: [edge | tail.functional]}

      _ ->
        # Default to syntactic for generic dependencies
        if exists?(tail.syntactic, target, type), do: tail, else: %{tail | syntactic: [edge | tail.syntactic]}
    end
  end

  defp exists?(list, target, type) do
    Enum.any?(list, fn e -> e.target_node_id == target and e.type == type end)
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
