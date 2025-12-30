defmodule CREMS.ChronoStack do
  @moduledoc """
  A persistent, immutable data structure for CREMS node history.
  Rejects the noise of constant metric fluctuation in favor of Significant State Transitions.
  """

  defstruct [
    :head_layer,   # Map: The current, mutable state map.
    :stack_layers  # List: [%Snapshot{}].
  ]

  @type t :: %__MODULE__{
    head_layer: map(),
    stack_layers: list()
  }

  defmodule Snapshot do
    @moduledoc """
    A deep copy of the Node state at the moment of transition.
    """
    defstruct [:timestamp, :hash, :data]
    
    @type t :: %__MODULE__{
      timestamp: DateTime.t(),
      hash: String.t(),
      data: map()
    }
  end

  @doc """
  Creates a new empty ChronoStack.
  """
  def new(initial_state \\ %{}) do
    # Initial state should ideally be a snapshot of the genesis state
    %__MODULE__{
      head_layer: initial_state,
      stack_layers: []
    }
  end

  @doc """
  Evolves the stack: Pushes the CURRENT head_layer to stack_layers,
  and updates head_layer with the new reality snapshot.
  (Ref: Spec 7.2 Evolve)
  """
  def evolve(stack, new_reality) do
    timestamp = DateTime.utc_now()
    # Hash the old head_layer before pushing it to the stack
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(stack.head_layer)) |> Base.encode16()
    
    snapshot = %Snapshot{
      timestamp: timestamp,
      hash: hash,
      data: stack.head_layer # Push the "old" reality
    }
    
    %{stack | 
      stack_layers: [snapshot | Enum.take(stack.stack_layers, 49)],
      head_layer: new_reality # Update with the "new" reality
    }
  end

  @doc """
  Directly updates the mutable head_layer (called by Sentinel).
  (Ref: Spec 7.1 head_layer)
  """
  def update_head(stack, updates) when is_map(updates) do
    %{stack | head_layer: Map.merge(stack.head_layer, updates)}
  end
end
