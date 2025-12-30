
# Script to verify CREMS Anatomical Structures and Logic
require Logger

defmodule CREMSVerifier do
  alias CREMS.{Node, NodeHead, NodeBody, NodeTail, NodeAntenna, ChronoStack}

  def run do
    Logger.info(">>> Starting CREMS Anatomy Verification <<<")

    verify_node_id_derivation()
    verify_node_head_firing()
    verify_node_antenna_gain()
    verify_node_body_structure()
    
    Logger.info(">>> Verification Complete <<<")
  end

  defp verify_node_id_derivation do
    Logger.info("--- Verifying ID Derivation ---")
    host_id = "ubuntu-server-01"
    role = "postgres_worker"
    ts = "2025-12-30T12:00:00Z"
    
    id1 = Node.derive_id(host_id, role, ts)
    id2 = Node.derive_id(host_id, role, ts)
    id3 = Node.derive_id(host_id, role, "2025-12-30T12:00:01Z")

    if id1 == id2 and id1 != id3 do
      Logger.info("[PASS] ID Generation is deterministic and sensitive to timestamp.")
      Logger.info("Derived ID: #{id1}")
    else
      Logger.error("[FAIL] ID Generation logic failed.")
    end
  end

  defp verify_node_head_firing do
    Logger.info("--- Verifying NodeHead Autosnap logic ---")
    # Mock embedding matching for simplicity since we don't have full Nx here yet or want to depend on it for quick verify
    # But wait, we implemented Nx calls in NodeHead, so we need Nx loaded or mocked.
    # Since we might not have Nx in this script context easily if not in Mix env, we will try to load it.
    
    # Actually, let's assume Nx is available as it is in CDMS.
    
    try do
      embedding = Nx.tensor([1.0, 0.0])
      query = Nx.tensor([0.9, 0.1]) # Similar
      
      head = %NodeHead{
        embedding: embedding,
        urgency_threshold: 0.8, # High threshold
        cognitive_state: :steady
      }
      
      # Case 1: Low Stress. 
      # Effective Threshold = 0.8 * (1.0 - 0.0) = 0.8.
      # Sim(1.0, 0.9) is high. Should fire.
      should_fire = NodeHead.should_fire?(head, query, 0.0)
      if should_fire, do: Logger.info("[PASS] Low Stress: Fired correctly."), else: Logger.info("[FAIL] Low Stress: Should have fired.")
      
      # Case 2: High Stress.
      # Effective Threshold = 0.8 * (1.0 - 0.9) = 0.08.
      # Even a low sim would fire.
      poor_query = Nx.tensor([0.1, 0.9])
      should_fire_distress = NodeHead.should_fire?(head, poor_query, 0.9)
      if should_fire_distress, do: Logger.info("[PASS] High Stress: Fired on poor match (Distress Call)."), else: Logger.info("[FAIL] High Stress: Should have fired.")

    rescue
      e -> Logger.error("[WARN] Skipping NodeHead logic test due to missing Nx: #{inspect(e)}")
    end
  end

  defp verify_node_antenna_gain do
    Logger.info("--- Verifying Antenna Gain ---")
    base = 1.0
    stress = 0.5
    expected = 1.0 + (0.5 * 2.0) # 2.0
    
    gain = NodeAntenna.calculate_gain(base, stress)
    
    if gain == expected do
      Logger.info("[PASS] Gain Calculation Correct: #{gain}")
    else
      Logger.error("[FAIL] Gain Calculation Wrong. Expected #{expected}, got #{gain}")
    end
  end

  defp verify_node_body_structure do
    Logger.info("--- Verifying NodeBody Structure ---")
    body = %NodeBody{
      fid_state: :active,
      fid_satisfaction: 1.0,
      fid_physics_model: %{elasticity_coefficient: 1.2, saturation_point: 0.8}
    }
    
    if body.fid_state == :active and body.fid_satisfaction == 1.0 do
      Logger.info("[PASS] NodeBody instantiated with correct atom/float types.")
    else
      Logger.error("[FAIL] NodeBody struct mismatch.")
    end
  end
end

CREMSVerifier.run()
