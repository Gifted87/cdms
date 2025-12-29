defmodule CMS.Services.Identity do
  @moduledoc """
  Provides identity services, primarily UUID generation.
  """

  @doc """
  Generates a deterministic UUID based on the path (v5).
  """
  def generate_uuid(path) do
    UUID.uuid5(:oid, path)
  end
end
