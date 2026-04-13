defmodule CMS.DataTail do
  @moduledoc """
  The Ledger: The administrative component of the Node Body.
  Holds physical metadata and integrity anchors.
  """

  @derive {Jason.Encoder, only: [:physical_symlink, :integrity_hash, :last_linked_hash, :mime_definition, :last_mutation, :salience_score, :permissions, :ownership, :immutable_flags, :genetic_provenance, :metabolism]}
  defstruct [
    :physical_symlink, # Absolute path to the OS file
    :integrity_hash,   # SHA-256 hash of the content
    :last_linked_hash, # Hash at time of last Phase 2 binding
    :mime_definition,  # Precise file type definition
    :last_mutation,    # DateTime of last detected change
    :chrono_stack,     # CMS.ChronoStack (History)
    :salience_score,   # Float 0.0 - 1.0 (Intrinsic importance)
    # Anatomical Ledger Fields
    :permissions,      # Map: %{user: "rwx", group: "r--", other: "r--"}
    :ownership,        # Map: %{uid: 1000, gid: 1000, owner_name: "gifted"}
    :immutable_flags,  # List: ["readonly"]
    :genetic_provenance, # Map: %{creator: :user | :installer, package: "apt:python"}
    :metabolism        # :static_bone | :fluid_blood
  ]

  @type t :: %__MODULE__{
    physical_symlink: String.t(),
    integrity_hash: String.t(),
    last_linked_hash: String.t() | nil,
    mime_definition: String.t(),
    last_mutation: DateTime.t(),
    chrono_stack: CMS.ChronoStack.t(),
    salience_score: float(),
    permissions: map(),
    ownership: map(),
    immutable_flags: [String.t()],
    genetic_provenance: map()
  }

  @doc """
  Creates a new Ledger.
  """
  def new(path, hash, mime, salience \\ 0.5, permissions \\ %{}, ownership \\ %{}, flags \\ [], provenance \\ %{}, metabolism \\ :static_bone) do
    %__MODULE__{
      physical_symlink: path,
      integrity_hash: hash,
      last_linked_hash: nil,
      mime_definition: mime,
      last_mutation: DateTime.utc_now(),
      chrono_stack: CMS.ChronoStack.new(),
      salience_score: salience,
      permissions: permissions,
      ownership: ownership,
      immutable_flags: flags,
      genetic_provenance: provenance,
      metabolism: metabolism
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

