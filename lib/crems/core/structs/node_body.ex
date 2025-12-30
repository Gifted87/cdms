defmodule CREMS.NodeBody do
  @moduledoc """
  The Vessel of State for a CREMS Node.
  Strictly partitioned into three sub-chambers: Identity, Physiology, and Reality.
  """

  defstruct [
    # --- Chamber 1: Identity ---
    :natural_language_fact, # String: Template-based description
    :semantic_tags,         # List[String]: derived from binary path and arguments

    # --- Chamber 2: Physiology (The "Feelings") ---
    :fid_state,          # Atom: :active | :sleeping | :uninterruptible | :zombie | :terminated
    :fid_telemetry,      # Map: %{cpu_load, ram_bytes, io_wait, net_in, net_out}
    
    # Alchemy Metrics
    :fid_satisfaction,   # Float (0.0 - 1.0): "Work Done" metric
    :fid_stress,         # Float (0.0 - 1.0): CPU/Queue backlog pressure
    :fid_strain,         # Float (0.0 - 1.0): RAM/Heap memory pressure
    :fid_agility,        # Float (0.0 - 1.0): Speed of thought/IO variation

    :fid_effect,         # String: Natural language description of physical sensation
    :fid_physics_model,  # Map: %{elasticity_coefficient: float(), saturation_point: float()} [Phantom Manifold]
    :fid_output,         # List: Circular buffer of last N lines of STDOUT/STDERR

    # --- Chamber 3: Reality Link ---
    :symbolic_link,      # Tuple: {:os_pid, 1234} or {:beam_pid, pid}
    :executable_path,    # String: Absolute path to the binary
    :data_tail           # %CREMS.DataTail{}: Ownership and Memory
  ]

  @type t :: %__MODULE__{
    natural_language_fact: String.t(),
    semantic_tags: [String.t()],
    fid_state: :active | :sleeping | :uninterruptible | :zombie | :terminated,
    fid_telemetry: map(),
    fid_satisfaction: float(),
    fid_stress: float(),
    fid_strain: float(),
    fid_agility: float(),
    fid_effect: String.t(),
    fid_physics_model: map(),
    fid_output: list(),
    symbolic_link: {atom(), any()},
    executable_path: String.t() | nil,
    data_tail: CREMS.DataTail.t()
  }
end
