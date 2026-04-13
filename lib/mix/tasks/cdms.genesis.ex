defmodule Mix.Tasks.Cdms.Genesis do
  use Mix.Task
  require Logger

  @shortdoc "Bootstraps the CDMS on a target directory"
  
  def run(args) do
    # 0. Start the App
    Mix.Task.run("app.start")
    
    {opts, [path_raw], _} = OptionParser.parse(args, switches: [mode: :string])
    
    path = Path.expand(path_raw || ".")
    cognitive_mode = case opts[:mode] do
      "deterministic" -> :deterministic
      _ -> :mode_a_deep
    end

    if path == "." and args == [] do
      Mix.raise("Usage: mix cdms.genesis /path/to/target [--mode deterministic|generative]")
    end

    if not File.dir?(path) do
      Mix.raise("Invalid directory: #{path}")
    end

    Logger.info("Starting CDMS Genesis for: #{path} (Mode: #{cognitive_mode})")

    case CMS.Services.GenesisCrawler.run(path, cognitive_mode: cognitive_mode) do
      {:ok, _} ->
        Logger.info("Genesis complete. Full cognitive graph established.")
        Logger.info("Monitor logs for progress. Press Ctrl+C to exit.")
        
        # Keep alive to allow async processes to finish their work
        :timer.sleep(:infinity)

      {:error, reason} ->
        Logger.error("Genesis failed: #{inspect(reason)}")
        Mix.raise("Genesis aborted.")
    end
  end
end