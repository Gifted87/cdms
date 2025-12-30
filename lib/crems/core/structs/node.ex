defmodule CREMS.Node do
  @moduledoc """
  The Fundamental Unit of the CREMS system.
  Ephemeral node, tied to a specific execution lifecycle.
  """

  defstruct [
    :id,      # String: Content-Addressable Hash (SHA-256)
    :head,    # CREMS.NodeHead
    :body,    # CREMS.NodeBody
    :tail,    # CREMS.NodeTail
    :antenna  # CREMS.NodeAntenna
  ]

  @type t :: %__MODULE__{
    id: String.t(),
    head: CREMS.NodeHead.t(),
    body: CREMS.NodeBody.t(),
    tail: CREMS.NodeTail.t(),
    antenna: CREMS.NodeAntenna.t()
  }

  @doc """
  Derives the Node ID.
  Formula: SHA256(Host_ID + Process_Role + Launch_Timestamp).
  """
  def derive_id(host_id, process_role, launch_timestamp) do
    plain_text = "#{host_id}#{process_role}#{launch_timestamp}"
    :crypto.hash(:sha256, plain_text) |> Base.encode16(case: :lower)
  end
end
