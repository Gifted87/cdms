defmodule CMS.MetaNode do
  @moduledoc """
  Factory for creating Meta-Nodes (nodes about nodes).
  """

  # FIX: Removed unused Edge alias
  alias CMS.Node

  @spec spawn_conflict(String.t(), map()) :: {:ok, CMS.Node.t()}
  def spawn_conflict(description, context_data) do
    head_text = "CONFLICT DETECTED: #{description}"
    data_head = CMS.DataHead.new(head_text)

    payload = %CMS.DataBodyPayload.Object{type: :object, object_type: :conflict_context, data: context_data}
    data_tail = CMS.DataTail.new("system://meta/conflict", "hash-placeholder", "application/x-cms-meta", 1.0)
    body = CMS.NodeBody.new(data_head, [payload], data_tail)

    {:ok, embedding} = CMS.Tool.Embedder.generate(head_text, "all-MiniLM-L6-v2")
    
    # Correctly derive UUID via content-addressability
    provenance = %{source: "CMS.IngestionEngine", method: "dialectical_merge"}
    uuid = CMS.NodeFactory.derive_content_addressable_id(body, provenance)
    
    head = CMS.NodeHead.new(uuid, embedding, "all-MiniLM-L6-v2", 0.99)
    antenna = CMS.NodeAntenna.new(uuid)
    
    {:ok, Node.new(head, body, antenna, provenance)}
  end
end
