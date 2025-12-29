defmodule CMS.SemanticRegion do
  @moduledoc """
  Manages Semantic Partitioning logic.

  Nodes are assigned to one of 256 regions based on their semantic embedding.
  """

  @num_regions 256

  @doc """
  Computes the region ID (0-255) for a given embedding and model version.
  """
  @spec compute_region_hash(Nx.Tensor.t() | list(), String.t()) :: integer()
  def compute_region_hash(embedding, model_version) do
    # 1. Ensure we have a binary representation (efficient for hashing)
    raw_data = if is_struct(embedding, Nx.Tensor), do: Nx.to_binary(embedding), else: :erlang.term_to_binary(embedding)

    # 2. Hashing and mapping to region space
    :crypto.hash(:sha256, "#{model_version}:" <> raw_data)
    |> :binary.decode_unsigned()
    |> rem(@num_regions)
  end

  @doc """
  Subscribes the current process to the relevant region topics.
  """
  def subscribe(region_id, node_id) do
    Phoenix.PubSub.subscribe(CMS.PubSub, "region:#{region_id}")
    Phoenix.PubSub.subscribe(CMS.PubSub, "node_pulse:#{node_id}")
    Phoenix.PubSub.subscribe(CMS.PubSub, "global:signals")
  end

  @doc """
  Unsubscribes from a region topic (used during Node Migration).
  """
  def unsubscribe(region_id, _node_id) do
    Phoenix.PubSub.unsubscribe(CMS.PubSub, "region:#{region_id}")
  end
end
