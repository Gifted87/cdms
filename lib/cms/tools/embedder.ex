defmodule CMS.Tool.Embedder do
  @moduledoc """
  Interface for generating vector embeddings via the Python ML Bridge.

  Connects to the local FastAPI service (ml_bridge.py) to convert text
  into dense vector representations for the CMS.VectorRouter.
  """

  require Logger

  # Configuration for the local Python Bridge
  defp bridge_url do
    Application.get_env(:acn_cms, :embedder_bridge_url, "http://localhost:5000/api/v1/embed")
  end
  @default_timeout 10_000 # 10 seconds

  @doc """
  Generates a vector embedding for the given text using the ML Bridge.

  Returns:
    {:ok, Nx.Tensor.t()} - The vector as an Nx Tensor.
    {:error, term()} - If the bridge is down or returns an error.
  """
  @spec generate(String.t(), String.t()) :: {:ok, Nx.Tensor.t()} | {:error, any()}
  def generate(text, model_version) do
    # Prepare the payload matching ml_bridge.py's EmbeddingRequest schema
    payload = %{
      text: text,
      model_version: model_version
    }

    # Execute request
    case Req.post(bridge_url(), json: payload, receive_timeout: @default_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        process_response(body)

      {:ok, %Req.Response{status: code, body: body}} ->
        Logger.error("Embedder Bridge Error [#{code}]: #{inspect(body)}")
        {:error, :bridge_error}

      {:error, exception} ->
        Logger.error("Embedder Connection Failed: #{inspect(exception)}")
        {:error, :connection_failed}
    end
  end

  # Internals

  defp process_response(%{"vector" => vector_list}) when is_list(vector_list) do
    # Convert the raw list of floats into an Nx Tensor
    tensor = Nx.tensor(vector_list)
    {:ok, tensor}
  end

  defp process_response(invalid_body) do
    Logger.error("Embedder received invalid response format: #{inspect(invalid_body)}")
    {:error, :invalid_response_format}
  end
end
