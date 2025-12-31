defmodule CREMS.Physics.Alchemist do
  @moduledoc """
  The Alchemist (The Observer): Pure functions converting telemetry into normalized feelings.
  Reference: Spec 4.0 The Physics Engines.
  """

  @doc """
  1. Stress (The Struggle)
  Formula: Sigmoid((cpu_load * 0.5) + (error_rate * 2.0))
  """
  def calculate_stress(cpu_load, error_rate) do
    # Input domains: cpu_load 0.0-1.0, error_rate 0.0-1.0
    x = (cpu_load * 0.5) + (error_rate * 2.0)
    # Sigmoid centered? Standard sigmoid 1 / (1 + e^-x)
    # For inputs 0.0 (idle), result is 0.5 (Neutral).
    # Spec implies "normalized feelings 0.0 - 1.0".
    # Usually 'Stress' 0 is good. Sigmoid(0) = 0.5. 
    # To map 0.0 input to 0.0 stress, we might shift? 
    # But sticking to "Formula: Sigmoid(...)" strictly.
    sigmoid(x)
  end

  @doc """
  2. Strain (The Capacity Limit)
  Formula: (ram_usage / max_ram)^2 + io_wait_factor
  """
  def calculate_strain(ram_usage, max_ram, io_wait_factor) do
    # Cap inputs?
    ratio = ram_usage / max_ram
    (ratio * ratio) + io_wait_factor
    |> min(1.0) # Normalized cap
  end

  @doc """
  3. Agility (The Responsiveness)
  Formula: ops_sec / (cpu_usage + epsilon)
  """
  def calculate_agility(ops_sec, cpu_usage) do
    epsilon = 0.0001
    efficiency = ops_sec / (cpu_usage + epsilon)
    
    # Normalize: "Efficiency" is unbounded. We need 0.0-1.0.
    # We'll use a tanh or similar to squash, or just clamp if ops/cpu is expected roughly 1:1 normalized.
    # Assuming ops and cpu are normalized or this is a relative metric.
    # For now, we clamp at 1.0 to satisfy "normalized".
    min(1.0, efficiency)
  end

  @doc """
  4. Satisfaction (Work Done)
  If total == 0: 1.0 (Idle is satisfied).
  Else: success / total.
  """
  def calculate_satisfaction(success_events, failure_events, state) do
     cond do
       state in [:zombie, :terminated, :error] -> 0.0
       (success_events + failure_events) == 0 -> 1.0
       true -> success_events / (success_events + failure_events)
     end
  end

  @doc """
  5. Feeling Description
  Output: String.
  """
  def describe(stress, strain, agility, satisfaction) do
    stress_desc = cond do
      stress > 0.8 -> "panicked"
      stress > 0.5 -> "stressed"
      stress > 0.2 -> "focused"
      true -> "calm"
    end

    strain_desc = cond do
      strain > 0.9 -> "critical overload"
      strain > 0.7 -> "significant strain"
      strain > 0.4 -> "moderate strain"
      true -> "light load"
    end

    agility_desc = cond do
      agility > 0.8 -> "blazing efficiency"
      agility > 0.5 -> "solid responsiveness"
      agility > 0.2 -> "steady pace"
      true -> "sluggish throughput"
    end

    sat_desc = cond do
      satisfaction > 0.9 -> "highly satisfied"
      satisfaction > 0.6 -> "performing well"
      satisfaction > 0.3 -> "struggling"
      true -> "dissatisfied"
    end
    
    "Feeling #{sat_desc} while #{stress_desc} under #{strain_desc} with #{agility_desc}"
  end

  # --- Transmutation Helpers (Mapping Telemetry to Physics) ---

  def transmute_os_metrics(metrics) do
    # Map OS telemetry to Physics inputs
    
    # 1. Stress
    # cpu_usage is 0-100. Normalize to 0-1.
    cpu_load = metrics.cpu_usage / 100.0
    # Error rate: Hard to know. Use 'State D' (Uninterruptible) as error proxy? 
    # Or keep 0.0 if unknown.
    error_rate = if metrics.state == "D", do: 0.5, else: 0.0
    stress = calculate_stress(cpu_load, error_rate)

    # 2. Strain
    # Soft limit 512MB
    max_ram = 2048 * 1024 * 1024 # Recalibrated to 2GB
    io_wait = if metrics.state == "D", do: 0.5, else: 0.0
    strain = calculate_strain(metrics.ram_bytes, max_ram, io_wait)

    # 3. Agility
    # Ops: Net packets/bytes. Normalize? 
    # CPU: usage 0-1.
    # Let's map normalized IO activity to 'ops'.
    # 100KB/s = 1.0 ops?
    ops = (metrics.net_in_delta + metrics.net_out_delta) / 102400.0
    agility = calculate_agility(ops, cpu_load)

    # 4. Satisfaction
    # Success = Out. Failure = (In - Out).
    # If In < Out, Failure = 0.
    success = metrics.net_out_delta
    failure = max(0, metrics.net_in_delta - metrics.net_out_delta)
    state_sym = if metrics.state in ["Z", "X", "T", "t"], do: :zombie, else: :running
    satisfaction = calculate_satisfaction(success, failure, state_sym)

    effect = describe(stress, strain, agility, satisfaction)

    %{
      stress: stress,
      strain: strain,
      agility: agility,
      satisfaction: satisfaction,
      state: metrics.state,
      effect: effect
    }
  end

  def transmute_beam_metrics(metrics) do
    # Map BEAM telemetry to Physics inputs

    # 1. Stress
    # CPU Load ~ Reductions/sec? No, let's use Queue as Error/Struggle proxy.
    # Spec: "Struggle".
    # We map Queue Length to "Error Rate" for this formula?
    # Or CPU? BEAM doesn't give explicit CPU % easily per actor.
    # Let's assume cpu_load = 0.1 (nominal) and map Queue to Error Rate.
    cpu_load = 0.1
    # Queue > 1000 = 1.0 error rate.
    error_rate = min(1.0, metrics.message_queue_len / 1000.0)
    stress = calculate_stress(cpu_load, error_rate)

    # 2. Strain
    # Heap. Max 10MB approx 1.3M words.
    max_heap = 1_300_000
    strain = calculate_strain(metrics.total_heap_size, max_heap, 0.0)

    # 3. Agility
    # Ops = Messages Out? Or Reductions?
    # Agility Spec: "Efficiency". High ops with low CPU.
    # Let's use Reductions as 'ops' and 'cpu' as time-cost? No, Reductions IS cost.
    # Let's use Msgs Out as Ops, Reductions as Cost (CPU).
    if Map.has_key?(metrics, :net_out_delta) do
       ops = metrics.net_out_delta # Messages out / sec
       cost = metrics.reductions_delta / 2000.0 # Normalized "CPU" cost
       calculate_agility(ops, cost)
    else
       # Fallback if no rigorous stats
       0.5
    end
    |> then(fn ag -> %{agility: ag} end)
    
    # 4. Satisfaction
    success = Map.get(metrics, :net_out_delta, 0)
    failure = max(0, Map.get(metrics, :net_in_delta, 0) - success)
    status_sym = if metrics.status == :suspended, do: :zombie, else: :running
    satisfaction = calculate_satisfaction(success, failure, status_sym)
    
    # Re-merge agility
    agility = 
       if Map.has_key?(metrics, :net_out_delta) do
          ops = metrics.net_out_delta
          # cost 0.0-1.0
          cost = max(0.0001, metrics.reductions_delta / 10000.0) 
          calculate_agility(ops, cost)
       else
          0.5
       end

    effect = describe(stress, strain, agility, satisfaction)

    %{
      stress: stress,
      strain: strain,
      agility: agility,
      satisfaction: satisfaction,
      state: metrics.status,
      effect: effect
    }
  end

  def transmute_beam_death(reason) do
     # Special case for death: strictly mapped
     satisfaction = 
       case reason do
         :normal -> 1.0
         :shutdown -> 1.0
         {:shutdown, _} -> 1.0
         _ -> 0.0
       end
       
     %{
       stress: 0.0, 
       strain: 0.0, 
       agility: 0.0, 
       satisfaction: satisfaction,
       state: :terminated,
       effect: "Terminated with reason: #{inspect(reason)}"
     }
  end

  # --- Internal ---

  defp sigmoid(x), do: 1.0 / (1.0 + :math.exp(-x))
end
