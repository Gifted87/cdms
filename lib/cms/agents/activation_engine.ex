defmodule CMS.ActivationEngine do
  use GenServer
  require Logger

  @moduledoc """
  Manages the Global Inhibition Mechanism.

  Implements Gap 16: Global Inhibition Signal / System Congestion.

  It maintains a public ETS table containing the current 'inhibition_factor'.
  NodeActors read this factor to modulate their Spreading Activation gain.
  High Congestion -> Low Factor -> Weaker Pulses -> Less Traffic.
  """

  # Constants
  @table_name :cms_global_inhibition_factor_ets
  @key :factor
  @default_factor 1.0 # 1.0 = Full Energy, 0.0 = Total Inhibition
  @congestion_topic "system_congestion"

  # API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Retrieves the current global inhibition factor (0.0 to 1.0).
  This is a high-frequency read operation optimized via ETS.
  """
  @spec get_global_inhibition_factor() :: float()
  def get_global_inhibition_factor do
    case :ets.lookup(@table_name, @key) do
      [{@key, value}] -> value
      _ -> @default_factor
    end
  end

  @doc """
  Injects a simulated congestion level for testing or external monitoring tools.
  Level: 0.0 (Idle) to 1.0 (Critical Load).
  """
  def set_congestion_level(level) do
    GenServer.cast(__MODULE__, {:congestion_level, level})
  end

  # Callbacks

  @impl true
  def init(:ok) do
    # Create public ETS table for read-heavy access by NodeActors
    :ets.new(@table_name, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.insert(@table_name, {@key, @default_factor})

    # Subscribe to system stats (e.g., from a LiveWire Agent or Telemetry)
    Phoenix.PubSub.subscribe(CMS.PubSub, @congestion_topic)

    Logger.info("CMS.ActivationEngine started. Global Factor: #{@default_factor}")
    {:ok, %{current_congestion: 0.0}}
  end

  @impl true
  def handle_cast({:congestion_level, level}, state) do
    new_factor = calculate_inhibition(level)
    update_ets(new_factor)

    Phoenix.PubSub.broadcast(CMS.PubSub, @congestion_topic, {:system_congestion, level})
    {:noreply, %{state | current_congestion: level}}
  end

  @impl true
  def handle_info({:system_congestion, level}, state) do
    new_factor = calculate_inhibition(level)
    update_ets(new_factor)
    Logger.debug("System Congestion #{level} -> Inhibition Factor #{new_factor}")
    {:noreply, %{state | current_congestion: level}}
  end

  # Internals

  defp calculate_inhibition(congestion) do
    # Linear degradation:
    # Congestion 0.0 -> Factor 1.0
    # Congestion 1.0 -> Factor 0.1 (Never fully 0 to allow critical alerts)

    clamped_congestion = max(0.0, min(1.0, congestion))
    max(0.1, 1.0 - (clamped_congestion * 0.9))
  end

  defp update_ets(factor) do
    :ets.insert(@table_name, {@key, factor})
  end
end
