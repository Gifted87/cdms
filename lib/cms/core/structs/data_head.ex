defmodule CMS.DataHead do
  @moduledoc """
  The Cognitive Interface: Holds the natural language summary and key concepts of a Node.
  """

  @derive {Jason.Encoder, only: [:summary, :concepts]}
  defstruct [
    :summary, # String: Natural language summary of the file's purpose.
    :concepts # List[String]: 3 key technical concepts found in the file.
  ]

  @type t :: %__MODULE__{
    summary: String.t(),
    concepts: [String.t()]
  }

  @doc """
  Creates a new DataHead.
  """
  def new(summary, concepts \\ []) do
    %__MODULE__{
      summary: summary,
      concepts: concepts
    }
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

