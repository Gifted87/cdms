defmodule CREMS.NodeAntenna do
  @moduledoc """
  The Synaptic Transceiver of a CREMS Node.
  Controls signal gain based on physiological stress.
  """

  defstruct [
    :gain,          # Float: Signal amplification factor
    :spatial_coord, # Tuple: {x, y, z}
    :error_conduit  # PID: Channel to the Passive Consciousness
  ]

  @type t :: %__MODULE__{
    gain: float(),
    spatial_coord: {float(), float(), float()},
    error_conduit: pid()
  }

  @doc """
  Calculates Gain based on Node Stress.
  Logic: Gain = Base_Gain + (NodeStress * 2.0).
  High Stress = High Gain ("The Shout").
  """
  def calculate_gain(base_gain, node_stress) do
    base_gain + (node_stress * 2.0)
  end
end
