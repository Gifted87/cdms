defmodule CREMS.Physics.PhantomManifold do
  @moduledoc """
  The Phantom Manifold (The Simulator): Pure functions converting history into Predictions.
  Reference: Spec 4.0 The Physics Engines (4.2).
  """

  @doc """
  Calculates Elasticity Coefficient (Brittleness) for the Phantom Engine.
  Formula: 1.0 / Resilience
  Where Resilience = 1.0 - (Strain_Rate_of_Change * Stress_Level)
  
  Interpretation:
  - 1.0: Perfectly Elastic (Linear response).
  - > 1.0: Brittle (Exponential response).
  """
  def calculate_elasticity_coefficient(history_buffer) do
    # History buffer is a list of physiological snapshots (maps)
    # We need at least 2 points to calculate rate of change.
    if length(history_buffer) < 2 do
      1.0 # Default Linear
    else
      [latest | rest] = history_buffer
      [previous | _] = rest
      
      # Strain Delta per tick
      strain_delta = latest.strain - previous.strain
      
      # Rate of Change: Positive slope implies stiffening/brittleness.
      rate_of_change = max(0.0, strain_delta)
      
      stress_level = latest.stress
      
      # Resilience (0.0 to 1.0)
      resilience = 1.0 - (rate_of_change * stress_level)
      clamped_resilience = max(0.1, resilience) # Avoid div/0, max brittleness 10.0
      
      1.0 / clamped_resilience
    end
  end

  @doc """
  Predicts Saturation (The Limit).
  Formula: Current_Load / (Predicted_Max_Capacity * 0.9)
  
  Concepts:
  - Current Load: Approximated by Strain (normalized capacity usage).
  - Predicted Max Capacity: Ideally 1.0 (since Strain is normalized).
  """
  def predict_saturation(current_strain, _history_buffer) do
    # Predicted Max Capacity. 
    # Since Strain is normalized 0.0-1.0, Max is 1.0.
    predicted_max = 1.0
    
    # Saturation = Load / (Max * 0.9)
    # If Load is 0.9, Saturation = 1.0 (Full).
    # If Load is 1.0, Saturation = 1.11 (Oversaturated).
    
    current_strain / (predicted_max * 0.9)
  end
end
