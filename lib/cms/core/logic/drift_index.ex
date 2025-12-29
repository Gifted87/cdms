defmodule CMS.Core.Logic.DriftIndex do
  @moduledoc """
  A lock-free, read-optimized registry for Node embeddings and metadata.
  
  Uses an ETS table to allow NodeActors to perform semantic lookups (Scatter-Gather)
  without blocking other actors or causing circular GenServer deadlocks.
  """

  @table :drift_index

  @doc """
  Initializes the ETS table. Called during application boot.
  """
  def init do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
  end

  @doc """
  Registers or updates a node's drift information in the index.
  """
  def register(node_id, embedding, region_id) do
    :ets.insert(@table, {node_id, embedding, region_id})
  end

  @doc """
  Removes a node from the index.
  """
  def unregister(node_id) do
    :ets.delete(@table, node_id)
  end

  @doc """
  Retrieves all active drift information records.
  Returns a list of {node_id, embedding, region_id}.
  """
  def get_all_drift_info do
    :ets.tab2list(@table)
  end
end
