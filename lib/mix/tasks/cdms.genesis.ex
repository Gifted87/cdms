defmodule Mix.Tasks.Cdms.Genesis do
  use Mix.Task
  require Logger

  @shortdoc "Bootstraps the CDMS on a target directory"
  
  def run(args) do
    # 0. Start the App
    Mix.Task.run("app.start")
    
    path = case args do
      [p] -> Path.expand(p)
      _ -> 
        Mix.raise("Usage: mix cdms.genesis /path/to/target")
    end

    if not File.dir?(path) do
      Mix.raise("Invalid directory: #{path}")
    end

    Logger.info("Starting CDMS Genesis for: #{path}")

    case CMS.Services.GenesisCrawler.run(path) do
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