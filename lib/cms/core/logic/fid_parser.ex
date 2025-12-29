defmodule CMS.FIDParser do
  @moduledoc """
  Provides functions for consuming Agents to parse and interpret
  CMS.DataBodyPayloads based on their Format ID (FID) type.

  Implements Gap 12: Polymorphic Consumption Logic.
  """

  alias CMS.DataBodyPayload.{Text, Code, Number, Link, Object}

  @doc """
  Parses a list of DataBodyPayloads, returning a list of raw usable content.
  """
  @spec parse_all([CMS.DataBodyPayload.t()]) :: list(any())
  def parse_all(payloads) when is_list(payloads) do
    Enum.map(payloads, &parse/1)
  end

  @doc """
  Parses a single DataBodyPayload into a usable primitive for an Agent.
  """
  @spec parse(CMS.DataBodyPayload.t()) :: any() | {:error, String.t()}

  # FID: Text -> Returns simple string
  def parse(%Text{content: content}), do: content

  # FID: Code -> Returns tuple {language, content} for the Specialist Agent to compile
  def parse(%Code{language: lang, content: content}), do: {lang, content}

  # FID: Number -> Returns {value, unit} for the Validator Agent (Regression Testing)
  def parse(%Number{value: value, unit: unit}), do: {value, unit}

  # FID: Link -> Returns URI. Agent must then query GM or External Web.
  def parse(%Link{uri: uri}), do: uri

  # FID: Object -> Returns the raw data map. Agent must interpret based on object_type.
  def parse(%Object{data: data}), do: data

  # Fallback for unknown/corrupt payloads
  def parse(other) do
    {:error, "Unknown or Malformed FID Payload: #{inspect(other)}"}
  end
end
