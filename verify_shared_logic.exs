
require Logger

defmodule SharedLogicVerifier do
  alias CMS.Core.Logic.CognitiveMath

  def run do
    Logger.info(">>> Starting Shared Logic Parity Verification <<<")

    test_relevance_score()
    test_adjusted_threshold()
    test_associative_boost()
    test_hebbian_weight()

    Logger.info(">>> Verification Complete <<<")
  end

  defp test_relevance_score do
    # Test strict equality of math
    v1 = Nx.tensor([1.0, 0.0])
    v2 = Nx.tensor([0.9, 0.1])
    # Dot product should be 0.9
    
    score = CognitiveMath.calculate_relevance_score(v1, v2, "A", "B")
    expected = 0.9
    
    # Allow small float error
    if abs(score - expected) < 0.001 do
      Logger.info("[PASS] Relevance Score Math correct: #{score}")
    else
      Logger.error("[FAIL] Relevance Score Math incorrect. Expected #{expected}, got #{score}")
    end
  end

  defp test_adjusted_threshold do
    # T_adj = Base / Inhibition
    # 0.5 / 0.5 = 1.0
    res = CognitiveMath.calculate_adjusted_threshold(0.5, 0.5, :steady)
    if res == 1.0, do: Logger.info("[PASS] Threshold Math correct."), else: Logger.error("[FAIL] Threshold Math.")
  end

  defp test_associative_boost do
    # Boost = Strength * f_type * f_context * resistance
    # 1.0 * 0.8 (semantic) * 1.0 * 0.8 = 0.64
    res = CognitiveMath.calculate_associative_boost(1.0, 1.0, :semantic, :default)
    if abs(res - 0.64) < 0.001, do: Logger.info("[PASS] Boost Math correct."), else: Logger.error("[FAIL] Boost Math.")
  end

  defp test_hebbian_weight do
    # 0.5 + 0.1 = 0.6
    res = CognitiveMath.calculate_new_hebbian_weight(0.5, 0.1)
    if res == 0.6, do: Logger.info("[PASS] Hebbian Update correct."), else: Logger.error("[FAIL] Hebbian Update.")
  end
end

SharedLogicVerifier.run()
