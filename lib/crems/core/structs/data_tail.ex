defmodule CREMS.DataTail do
  @moduledoc """
  The Anatomical Ledger and Memory of a CREMS Node.
  Hosts ownership, capabilities, and the ChronoStack.
  """

  defstruct [
    :ownership,     # Map: %{uid: integer(), user: string(), gid: integer(), group: string()}
    :capabilities,  # List[string]: Linux capabilities or similar
    :chrono_stack   # %CREMS.ChronoStack{}
  ]

  @type t :: %__MODULE__{
    ownership: map(),
    capabilities: [String.t()],
    chrono_stack: CREMS.ChronoStack.t()
  }

  @doc """
  Creates a new DataTail.
  """
  def new(uid, user, gid, group) do
    %__MODULE__{
      ownership: %{uid: uid, user: user, gid: gid, group: group},
      capabilities: [],
      chrono_stack: CREMS.ChronoStack.new()
    }
  end
end
