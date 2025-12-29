defmodule CMS.Core.Logic.PhysiologyEngine do
  @moduledoc """
  The Physiology Engine: Manages metabolic rates and temporal flow.
  Implements the Sliding Window Buffer and the 5-Minute Heartbeat.
  """
  
  use GenServer
  require Logger
  alias CMS.ChronoStack

  @table :physiology_buffer
  @window_size 3000
  @heartbeat_interval 300_000 # 5 minutes

  # --- Client API ---

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Buffers content for a Blood Node. 
  Only keeps the latest 3,000 characters.
  """
  def buffer_blood(node_id, content) do
    # Take latest 3,000 chars
    slice = if String.length(content) > @window_size do
      String.slice(content, -@window_size..-1)
    else
      content
    end
    
    :ets.insert(@table, {node_id, slice, DateTime.utc_now()})
  end

  @doc """
  Manually triggers the heartbeat for testing.
  """
  def trigger_heartbeat do
    send(__MODULE__, :heartbeat)
  end

  # --- Callbacks ---

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table])
    
    # Start the 5-minute heartbeat
    schedule_heartbeat()
    
    {:ok, %{}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    IO.puts("\n[HEARTBEAT] Rhythmic Sampling of Blood Nodes...\n")
    
    # Process all buffered nodes
    :ets.tab2list(@table)
    |> Enum.each(fn {node_id, buffer_content, _ts} -> 
       process_blood_pulse(node_id, buffer_content)
    end)
    
    schedule_heartbeat()
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp process_blood_pulse(node_id, buffer_content) do
    # 1. Fetch node from registry/mnesia
    case CMS.NodeSupervisor.get_node(node_id) do
      {:ok, node} ->
        old_body_content = CMS.NodeBody.decompress(node.body)
        
        # 2. The Check: Compare current window with last saved
        if old_body_content != buffer_content do
          Logger.info("PhysiologyEngine: Heartbeat detected change for Blood Node #{node_id}. Pulsing...")
          
          # 3. The Pulse: Push snapshot (Max 10 for Blood)
          old_hash = node.body.data_ledger.integrity_hash
          new_hash = :crypto.hash(:sha256, buffer_content) |> Base.encode16(case: :lower)
          
          new_stack = ChronoStack.push(node.body.data_ledger.chrono_stack, old_body_content, buffer_content, old_hash, :metabolic_pulse, 10)
          
          # Update Ledger & Body
          new_ledger = %{node.body.data_ledger | 
            integrity_hash: new_hash, 
            last_mutation: DateTime.utc_now(),
            chrono_stack: new_stack
          }
          
          new_body = %{node.body | data_body: buffer_content, data_ledger: new_ledger}
          new_node = %{node | body: new_body}
          
          # 4. Result: Time-lapse update
          # Notify actor and persist
          case Registry.lookup(CMS.NodeRegistry, node_id) do
            [{pid, _}] -> GenServer.cast(pid, {:update_node, new_node})
            _ -> :ok # If actor died, persistence handled by direct mnesia if desired?
                    # For now, we rely on NodeActor to handle persistence via update_node.
          end
        end
      _ -> 
        # Node might have been deleted, clean up buffer
        :ets.delete(@table, node_id)
    end
  end
end
