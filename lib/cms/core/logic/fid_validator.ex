defmodule CMS.FIDValidator do
  @moduledoc """
  Validates the structural integrity of DataBodyPayloads during Ingestion.
  """

  alias CMS.DataBodyPayload.{Text, Code, Number, Link, Object}

  @spec validate(CMS.DataBodyPayload.t()) :: :ok | {:error, String.t()}

  def validate(%Text{content: c}) when is_binary(c) and byte_size(c) > 0, do: :ok
  def validate(%Text{}), do: {:error, "FID: Text content must be a non-empty string"}

  def validate(%Code{language: l, content: c}) when is_atom(l) and is_binary(c), do: :ok
  def validate(%Code{}), do: {:error, "FID: Code must have an atom language and string content"}

  def validate(%Number{value: v}) when is_number(v), do: :ok
  def validate(%Number{}), do: {:error, "FID: Number value must be integer or float"}

  def validate(%Link{uri: u}) when is_binary(u) do
    if Regex.match?(~r/^(http|https|gm|ipfs):\/\//, u) do
      :ok
    else
      {:error, "FID: Link URI must start with http, https, gm, or ipfs"}
    end
  end
  def validate(%Link{}), do: {:error, "FID: Link URI missing"}

  def validate(%Object{data: d}) when is_map(d), do: :ok
  def validate(%Object{}), do: {:error, "FID: Object data must be a map"}

  def validate(unknown), do: {:error, "Unknown struct type: #{inspect(unknown)}"}
end
