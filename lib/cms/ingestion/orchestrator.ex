defmodule CMS.Ingestion.Orchestrator do
  @moduledoc """
  Manages the async task of processing large uploads so the API doesn't time out.
  """
  
  alias CMS.Ingestion.Crawler
  require Logger

  # Supervisor name
  @supervisor CMS.Ingestion.TaskSupervisor

  @doc """
  Starts an async ingestion task for the given path.
  Returns {:ok, pid} of the task.
  """
  def start_ingestion(path_or_upload, _opts \\ []) do
     Task.Supervisor.async_nolink(@supervisor, fn ->
        try do
          Logger.info("[Orchestrator] Ingestion started for: #{path_or_upload}")
          broadcast_start()
          result = run_crawler(path_or_upload)
          case result do
             {:ok, root_id} -> 
                Logger.info("[Orchestrator] Ingestion COMPLETE for #{path_or_upload}. Root Node: #{root_id}")
                broadcast_complete(result)
             {:error, reason} -> 
                Logger.error("[Orchestrator] Ingestion FAILED: #{inspect(reason)}")
                broadcast_failed(reason)
             other -> 
                Logger.error("[Orchestrator] Ingestion returned unexpected result: #{inspect(other)}")
                broadcast_failed(:unknown_error)
          end
          result
        rescue
          e -> 
             Logger.error("[Orchestrator] CRITICAL FAILURE during ingestion: #{inspect(e)}")
             broadcast_failed(e)
             {:error, e}
        end
     end)
  end
  
  defp run_crawler(path) when is_binary(path) do
    Crawler.crawl(path)
  end
  
  defp broadcast_start() do
    Phoenix.PubSub.broadcast(CMS.PubSub, "crawler:progress", {:ingestion_started, %{pid: self()}})
  end
  
  defp broadcast_complete({:ok, root_id}) do
    Phoenix.PubSub.broadcast(CMS.PubSub, "crawler:progress", {:ingestion_complete, %{root_id: root_id}})
  end

  defp broadcast_failed(reason) do
     Phoenix.PubSub.broadcast(CMS.PubSub, "crawler:progress", {:ingestion_failed, reason})
  end
end
