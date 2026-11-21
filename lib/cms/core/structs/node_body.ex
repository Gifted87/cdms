defmodule CMS.NodeBody do
  @moduledoc """
  The Vessel of Content: Holds the semantic and physical truth of a file.
  """

  # Custom Jason.Encoder implemented below to handle binary data_body

  defstruct [
    :data_head,   # %CMS.DataHead{} (Summary & Concepts)
    :data_body,   # Binary (Compressed Content) or Nil (Shallow)
    :data_ledger, # %CMS.DataTail{} (The Ledger)
    :mode         # :deep (Mode A), :shallow (Mode B), or :deterministic (No-LLM)
  ]

  @type t :: %__MODULE__{
    data_head: CMS.DataHead.t(),
    data_body: binary() | nil,
    data_ledger: CMS.DataTail.t(),
    mode: :deep | :shallow | :deterministic
  }

  @doc """
  Creates a new NodeBody.
  Stores content in its raw form.
  """
  def new(head, body_content, ledger, mode \\ :deep) do
    %__MODULE__{
      data_head: head,
      data_body: body_content,
      data_ledger: ledger,
      mode: mode
    }
  end

  @doc """
  Returns the data_body as is.
  """
  def decompress(%__MODULE__{data_body: body}), do: body
  def decompress(_), do: nil

  # --- JSON Encoding ---

  defimpl Jason.Encoder, for: __MODULE__ do

    def encode(value, opts) do
      # Convert binary data_body to Base64 for JSON serialization
      {body_data, is_base64} = 
        if is_binary(value.data_body) do
          {Base.encode64(value.data_body), true}
        else
          {value.data_body, false}
        end

      %{
        data_head: value.data_head,
        data_body: body_data,
        data_body_is_base64: is_base64,
        data_ledger: value.data_ledger,
        mode: value.mode
      }
      |> Jason.Encode.map(opts)
    end
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

