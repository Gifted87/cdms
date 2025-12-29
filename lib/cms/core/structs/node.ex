defmodule CMS.Node do
  @moduledoc """
  The Quad-Partite Node: The anatomical unit of the CDMS.
  """

  @derive {Jason.Encoder, only: [:id, :head, :body, :tail, :antenna, :created_at, :last_fired]}
  defstruct [
    :id,         # 128-bit persistent UUID
    :head,       # %CMS.NodeHead{} (Cognitive Interface)
    :body,       # %CMS.NodeBody{} (Vessel of Content)
    :tail,       # %CMS.NodeTail{} (The Connectome)
    :antenna,    # %CMS.NodeAntenna{} (Signal Modulation)
    :provenance, # Map (Source Metadata & Trust)
    :created_at, # DateTime of creation
    :last_fired  # DateTime of last activation
  ]

  @type t :: %__MODULE__{
    id: String.t(),
    head: CMS.NodeHead.t(),
    body: CMS.NodeBody.t(),
    tail: CMS.NodeTail.t(),
    antenna: CMS.NodeAntenna.t(),
    provenance: map(),
    created_at: DateTime.t(),
    last_fired: DateTime.t()
  }

  @doc """
  Creates a new Quad-Partite Node.
  """
  def new(head, body, antenna, provenance \\ %{}, created_at \\ nil, last_fired \\ nil) do
    now = DateTime.utc_now()
    %__MODULE__{
      id: head.uuid,
      head: head,
      body: body,
      tail: CMS.NodeTail.new(),
      antenna: antenna,
      provenance: provenance,
      created_at: created_at || now,
      last_fired: last_fired || now
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

