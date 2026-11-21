defmodule CodeGraphEngine do
  @moduledoc """
  Core engine for processing and traversing code graph structures.
  """

  @doc """
  Initializes a new graph node with the given metadata.
  """
  def init_node(id, type, metadata \\ %{}) do
    %{
      id: id,
      type: type,
      metadata: metadata,
      edges: []
    }
  end

  @doc """
  Adds a directed edge between two nodes.
  """
  def add_edge(graph, from_id, to_id, label) do
    Map.update!(graph, :edges, fn edges ->
      [%{from: from_id, to: to_id, label: label} | edges]
    end)
  end
end
