defmodule VerificationMath do
  def calculate_adjusted_threshold(t_base, i_global, internal_state) do
    c_metabolic = case internal_state do
      :high_energy -> 0.9
      :high_energy_state -> 0.9
      :low_energy -> 1.2
      :hibernating -> 1.5
      _ -> 1.2
    end
    
    safe_inhibition = max(0.1, i_global)
    (t_base / safe_inhibition) * c_metabolic
  end

  def calculate_associative_boost(r_origin_times_weight, _redundant_weight, type, context_mode) do
    f_type = case type do
      :dependency -> 1.0
      :causes -> 0.9
      :relates_to -> 0.8
      :semantic -> 0.8
      :contradicts -> 0.2
      :child_of -> 1.0
      _ -> 0.5
    end

    f_context = case context_mode do
      :brainstorm -> 1.5
      _ -> 1.0
    end

    synaptic_resistance = 0.3

    r_origin_times_weight * f_type * f_context * synaptic_resistance
  end
end

IO.puts "--- Verification: Math ---"

# 1. Test Threshold
# Normal case: Base 0.35, Inhibition 1.0, Low Energy (1.2)
# Expected: (0.35 / 1.0) * 1.2 = 0.42
t1 = VerificationMath.calculate_adjusted_threshold(0.35, 1.0, :low_energy)
IO.puts "T1 (Normal): #{t1} (Expected 0.42)"

# Congested case: Base 0.35, Inhibition 0.1, High Energy (0.9)
# Expected: (0.35 / 0.1) * 0.9 = 3.5 * 0.9 = 3.15
t2 = VerificationMath.calculate_adjusted_threshold(0.35, 0.1, :high_energy)
IO.puts "T2 (Congested): #{t2} (Expected 3.15)"

# 2. Test Boost
# Origin 1.0 * Weight 0.8 = 0.8 incoming strength.
# Type :semantic (0.8), Context Default (1.0), Resistance (0.3)
# Expected: 0.8 * 0.8 * 1.0 * 0.3 = 0.192
b1 = VerificationMath.calculate_associative_boost(0.8, 1.0, :semantic, :default)
IO.puts "B1 (Semantic): #{b1} (Expected 0.192)"

if abs(t1 - 0.42) < 0.001 and abs(t2 - 3.15) < 0.001 and abs(b1 - 0.192) < 0.001 do
  IO.puts "SUCCESS: Math formulas verified."
else
  IO.puts "FAILURE: Math formulas incorrect."
  System.halt(1)
end
