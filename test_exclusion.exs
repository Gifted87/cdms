
# Script to verify ExclusionCortex and simulated LiveWire behavior
# Run with: elixir test_exclusion.exs

require Logger

# Mocking the exclusion list verification
IO.puts "--- Verifying ExclusionCortex ---"

exclusions = [
  "/home/gifted/cdms/memory_cartridges/epoch_123.jsonl",
  "/home/gifted/cdms/priv/data/mnesia_store/LATEST.LOG",
  "/home/gifted/cdms/deps/phoenix/lib/phoenix.ex",
  "/home/gifted/cdms/_build/dev/lib/cdms/ebin/cdms.app"
]

inclusions = [
  "/home/gifted/cdms/lib/cms/core/node.ex",
  "/home/gifted/cdms/README.md",
  "/home/gifted/cdms/config/config.exs"
]

Enum.each(exclusions, fn path ->
  allowed = CMS.Ingestion.ExclusionCortex.should_traverse?(path)
  status = if allowed, do: "FAIL (Allowed)", else: "PASS (Blocked)"
  IO.puts "Path: #{path} -> #{status}"
end)

Enum.each(inclusions, fn path ->
  allowed = CMS.Ingestion.ExclusionCortex.should_traverse?(path)
  status = if allowed, do: "PASS (Allowed)", else: "FAIL (Blocked)"
  IO.puts "Path: #{path} -> #{status}"
end)

IO.puts "\n--- Verifying LiveWire Logic Simulation ---"
# Simulate the logic I added to LiveWire
path = "/home/gifted/cdms/memory_cartridges/infinite_loop.log"
if CMS.Ingestion.ExclusionCortex.should_traverse?(path) do
  IO.puts "LiveWire would PROCESS #{path} -> FAIL"
else
  IO.puts "LiveWire would DROP #{path} -> PASS"
end
