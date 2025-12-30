# Verification of CognitiveMath.linear_regression

defmodule VerifyMath do
  def run do
    # 1. Linear Test: y = 2x + 1
    points = [{1.0, 3.0}, {2.0, 5.0}, {3.0, 7.0}, {4.0, 9.0}]
    IO.puts("Testing Linear: y = 2x + 1")
    case CMS.Core.Logic.CognitiveMath.linear_regression(points) do
      {:ok, %{slope: m, intercept: b}} ->
        IO.puts("Slope: #{m} (expected 2.0)")
        IO.puts("Intercept: #{b} (expected 1.0)")
      error -> IO.inspect(error)
    end

    # 2. Log-Log Test (Exponential): y = x^3 => log(y) = 3 * log(x)
    # x = [e^1, e^2, e^3] => log(x) = [1, 2, 3]
    # y = [e^3, e^6, e^9] => log(y) = [3, 6, 9]
    log_points = [{1.0, 3.0}, {2.0, 6.0}, {3.0, 9.0}]
    IO.puts("\nTesting log-log: Slope should be 3.0")
    case CMS.Core.Logic.CognitiveMath.linear_regression(log_points) do
      {:ok, %{slope: m}} ->
        IO.puts("Slope: #{m} (expected 3.0)")
      error -> IO.inspect(error)
    end
    
    # 3. Agility Test (Saturation projection): y = -0.1x + 1.0
    # y = 0 when x = 10.0
    agility_points = [{0.0, 1.0}, {5.0, 0.5}, {8.0, 0.2}]
    IO.puts("\nTesting Agility projection: x-intercept should be 10.0")
    case CMS.Core.Logic.CognitiveMath.linear_regression(agility_points) do
      {:ok, %{slope: m, intercept: b}} ->
         x_int = -b / m
         IO.puts("Projected Saturation: #{x_int} (expected 10.0)")
      error -> IO.inspect(error)
    end
  end
end

VerifyMath.run()
