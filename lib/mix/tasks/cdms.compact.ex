defmodule Mix.Tasks.Cdms.Compact do
  use Mix.Task
  require Logger

  @shortdoc "Compacts CDMS Epoch Logs by keeping only the latest version of each node."

  def run(_args) do
    # Ensure app is started to get config
    Mix.Task.run("app.start")
    
    epoch_dir = get_epoch_dir()
    IO.puts "--- CDMS Log Compaction Tool ---"
    IO.puts "Target: #{epoch_dir}"

    if not File.dir?(epoch_dir) do
      # Try alternative path seen in some environments
      alt_dir = "memory_cartridges/default/epochs"
      if File.dir?(alt_dir) do
        IO.puts "Redirecting to alt directory: #{alt_dir}"
        do_compact(alt_dir)
      else
        IO.puts "Error: Epoch directory not found at #{epoch_dir} or #{alt_dir}."
      end
    else
      do_compact(epoch_dir)
    end
  end

  defp do_compact(epoch_dir) do
    files = 
      File.ls!(epoch_dir)
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.filter(&(not String.contains?(&1, "compacted"))) # Don't re-compact already compacted unless forced?
      |> Enum.sort()
      |> Enum.map(&Path.join(epoch_dir, &1))

    if files == [] do
      IO.puts "No non-compacted logs found to compact."
    else
      IO.puts "Found #{length(files)} files. Scanning for latest snapshots..."

    # Use a Map to ensure only the latest state for each UUID is preserved
    compacted_state = Enum.reduce(files, %{}, fn path, acc ->
      IO.puts "  Processing #{Path.basename(path)}..."
      File.stream!(path)
      |> Stream.map(fn line -> 
         case Jason.decode(line) do
           {:ok, data} -> data
           _ -> nil
         end
      end)
      |> Enum.reduce(acc, fn 
        %{"entity" => "node", "id" => id} = event, inner_acc ->
           if event["type"] in ["node_created", "node_updated"] do
             Map.put(inner_acc, id, event)
           else
             inner_acc
           end
        _, inner_acc -> inner_acc
      end)
    end)

    unique_count = map_size(compacted_state)
    IO.puts "\nScan complete. Unique nodes found: #{unique_count}"

    # Write compacted log
    ts_str = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-") |> String.replace(".", "-")
    new_filename = "epoch_compacted_#{ts_str}.jsonl"
    new_path = Path.join(epoch_dir, new_filename)

    IO.puts "Writing compacted log to #{new_filename}..."
    
    File.open!(new_path, [:write, :utf8], fn file ->
      Enum.each(compacted_state, fn {_, event} ->
        IO.write(file, Jason.encode!(event) <> "\n")
      end)
    end)

    IO.puts "\n✅ Success! Compacted log created."
    IO.puts "--------------------------------------------------"
    IO.puts "CRITICAL STEP: To complete the cleanup:"
    IO.puts "1. Move the old .jsonl files to a backup directory."
    IO.puts "2. Keep ONLY #{new_filename} in the epochs directory."
    IO.puts "3. Restart CDMS. Rehydration will now be near-instant (~#{unique_count} nodes)."
    IO.puts "--------------------------------------------------"
    end
  end

  defp get_epoch_dir do
    data_root = Application.get_env(:acn_cms, :data_root) || "priv/data"
    Path.join(data_root, "epochs")
  end
end
