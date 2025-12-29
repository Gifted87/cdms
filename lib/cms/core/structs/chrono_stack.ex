defmodule CMS.ChronoStack do
  @moduledoc """
  The Chrono Stack: Maintains a Merkle-Linked history of Node changes.
  Uses Delta Compression (Reverse Diffs) to store history efficiently.
  """

  @derive {Jason.Encoder, only: [:snapshots]}
  defstruct [
    snapshots: [] # List of Snapshot structs
  ]

  # --- Access Behavior ---
  @behaviour Access

  @impl Access
  def fetch(term, key), do: Map.fetch(term, key)

  @impl Access
  def get_and_update(term, key, fun), do: Map.get_and_update(term, key, fun)

  @impl Access
  def pop(term, key), do: Map.pop(term, key)

  defmodule Snapshot do
    @derive {Jason.Encoder, only: [:timestamp, :hash, :diff, :cause]}
    defstruct [:timestamp, :hash, :diff, :cause]

    # --- Access Behavior ---
    @behaviour Access

    @impl Access
    def fetch(term, key), do: Map.fetch(term, key)

    @impl Access
    def get_and_update(term, key, fun), do: Map.get_and_update(term, key, fun)

    @impl Access
    def pop(term, key), do: Map.pop(term, key)
  end

  @doc """
  Creates a new empty ChronoStack.
  """
  def new, do: %__MODULE__{snapshots: []}

  @doc """
  Pushes a new state onto the stack.
  Calculates the DIFF between the NEW content and the OLD content.
  The Stack stores the PREVIOUS state as a Reverse Diff (how to get back to it from current).
  
  So if we have State A. We move to State B.
  NodeBody has State B.
  Stack has [Diff(B -> A)].
  """
  def push(stack, old_content, new_content, old_hash, cause \\ :livewire_mutation, max_depth \\ nil)
  def push([], old_c, new_c, hash, cause, max_depth), do: push(new(), old_c, new_c, hash, cause, max_depth)
  def push(stack, old_content, new_content, old_hash, cause, max_depth) do
    # Calculate Diff: How to turn New -> Old (Reverse Diff)
    # Since we don't have a library for "Patching", we will store the Myers Difference
    # relative to the NEW content to get the OLD content.
    
    diff = if old_content && new_content && String.valid?(old_content) && String.valid?(new_content) do
       List.myers_difference(String.to_charlist(new_content), String.to_charlist(old_content))
       |> inspect()
    else
       if old_content, do: "BINARY_OR_INVALID_UTF8_CHANGE", else: "ROOT_GENESIS"
    end

    snapshot = %Snapshot{
      timestamp: DateTime.utc_now(),
      hash: old_hash,
      diff: diff,
      cause: cause
    }

    snapshots = [snapshot | stack.snapshots]
    
    # Truncate if max_depth is set
    snapshots = if max_depth, do: Enum.take(snapshots, max_depth), else: snapshots

    new_stack = %{stack | snapshots: snapshots}

    new_stack
  end
end
