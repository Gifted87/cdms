defmodule Mix.Tasks.Cdms.Bind do
  @moduledoc "Resolves Ghost Nodes into real dependencies (Phase 5)"
  use Mix.Task
  require Logger

  def run(_args) do
    Mix.Task.run("app.start")
    
    Logger.info("CDMS BINDER: Initiating Call Graph Resolution Pass...")
    
    case CMS.Ingestion.CallGraphBinder.run_pass() do
      :ok ->
        Logger.info("CDMS BINDER: Resolution Pass Complete.")
      {:error, reason} ->
        Logger.error("CDMS BINDER: Resolution Pass Failed: #{inspect(reason)}")
    end
  end
end
