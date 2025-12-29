defmodule CMS.NodeAntenna do
  @moduledoc """
  The Antenna: Modulates the signal strength of a Node based on semantic importance and activity.
  """

  @derive Jason.Encoder
  defstruct [
    :gain,
    :salience,
    :frequency,
    :resonance_pattern,
    :dampening_factors
  ]

  @type t :: %__MODULE__{
    gain: float(),
    salience: float(),
    frequency: integer(), # Mutation count or similar
    resonance_pattern: String.t(),
    dampening_factors: [String.t()]
  }

  @doc """
  Creates a new Antenna with initial gain based on salience and file path.
  Gain calculation: Salience * 2.0
  """
  def new(path, salience \\ nil) do
    # Use provided salience or calculate heuristic baseline
    effective_salience = salience || calculate_initial_gain(path)
    
    # Gain = Salience * 2.0 (as per spec)
    gain = effective_salience * 2.0
    
    dampening = calculate_dampening_factors(path)
    dampening = if Enum.empty?(dampening), do: ["signal_established"], else: dampening
    
    %__MODULE__{
      gain: gain,
      salience: effective_salience,
      frequency: 100,
      resonance_pattern: "stable",
      dampening_factors: dampening
    }
  end

  @doc """
  Calculates the initial gain based on file type/extension.
  Spec: Source(0.8), Config(0.8), Doc(0.6), Log/Temp(0.1), Vendor(0.2).
  """
  def calculate_initial_gain(path) do
    cond do
      vendor?(path) -> 0.2
      log_or_temp?(path) -> 0.1
      source_code?(path) -> 0.8
      config?(path) -> 0.8
      documentation?(path) -> 0.6
      true -> 0.5
    end
  end

  defp calculate_dampening_factors(path) do
    factors = []
    factors = if vendor?(path), do: ["vendor_directory" | factors], else: factors
    factors = if generated_code?(path), do: ["generated_code" | factors], else: factors
    factors = if log_or_temp?(path), do: ["noise_file" | factors], else: factors
    factors
  end

  defp source_code?(path), do: String.match?(path, ~r/\.(ex|exs|py|js|ts|go|rs|c|cpp|rb|java)$/)
  defp config?(path), do: String.match?(path, ~r/(\.yaml|\.json|\.toml|\.ini|config|mix\.exs)$/)
  defp documentation?(path), do: String.match?(path, ~r/(\.md|\.txt|LICENSE|README)$/)
  defp vendor?(path), do: String.contains?(path, ["node_modules", "deps", "vendor", "_build", "target"])
  defp log_or_temp?(path), do: String.match?(path, ~r/(\.log|\.tmp|\.lock)$/)
  defp generated_code?(path), do: String.contains?(path, ["generated", "auto-generated"])

  # --- Access Behavior ---
  @behaviour Access

  @impl Access
  def fetch(term, key), do: Map.fetch(term, key)

  @impl Access
  def get_and_update(term, key, fun), do: Map.get_and_update(term, key, fun)

  @impl Access
  def pop(term, key), do: Map.pop(term, key)
end

