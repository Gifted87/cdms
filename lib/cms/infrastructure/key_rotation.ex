defmodule CMS.Infrastructure.KeyRotation do
  @moduledoc """
  Manages sequential API key rotation for Gemini requests.
  Ensures that once a key has been used, the next API call will use the next key in line.
  """
  use GenServer
  require Logger

  defstruct [:keys, :index, :count]

  # --- Client API ---

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Retrieves the next key in the rotation sequence.
  """
  def get_next_key do
    GenServer.call(__MODULE__, :get_next_key)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    keys = Application.get_env(:acn_cms, :gemini_api_keys) || []
    count = length(keys)
    
    if count == 0 do
      Logger.warning("[KeyRotation] No Gemini API keys configured.")
    else
      Logger.info("[KeyRotation] Initialized with #{count} keys.")
    end

    {:ok, %__MODULE__{keys: keys, index: 0, count: count}}
  end

  @impl true
  def handle_call(:get_next_key, _from, %{count: 0} = state) do
    {:reply, nil, state}
  end

  @impl true
  def handle_call(:get_next_key, _from, state) do
    key = Enum.at(state.keys, state.index)
    new_index = rem(state.index + 1, state.count)
    {:reply, key, %{state | index: new_index}}
  end
end
