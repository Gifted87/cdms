defmodule CMS.Infrastructure.OllamaBridge do
  @moduledoc """
  The Ollama Bridge: Manages communication with the local Ollama instance.
  Implements token bucket rate limiting to prevent GPU saturation.
  """

  use GenServer
  require Logger

  @base_url "http://localhost:11434"
  @inference_limit 5
  @embedding_limit 20

  defstruct [:inference_tokens, :embedding_tokens, :inference_queue, :embedding_queue]

  # --- Client API ---

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Summarizes file content using the specified LLM.
  Retries on bad responses until we get something usable.
  Pass file_path for better context in prompts.
  """
  def summarize(content, model \\ "qwen3:0.6b", file_path \\ nil, retries \\ 3) do
    if Mix.env() == :test do
      {:ok, %{"summary" => "Test Summary", "concepts" => ["Term1", "Term2", "Term3"]}}
    else
      GenServer.call(__MODULE__, {:request, :inference, fn ->
        attempt_summarize(content, model, retries, file_path)
      end}, :infinity)
    end
  end

  defp attempt_summarize(content, model, retries_left, file_context) do
    # Extract filename and extension for context
    {filename, extension} = if file_context do
      {Path.basename(file_context), Path.extname(file_context)}
    else
      {"unknown", ""}
    end
    
    prompt = """
    You are analyzing source code file: #{filename}
    File type: #{extension}
    
    READ THIS CODE CAREFULLY:
    #{String.slice(content, 0, 3000)}
    
    TASK: Write a CLEAR, SPECIFIC summary (NOT dots or placeholders).
    
    RULES:
    1. Summary MUST be a complete sentence describing what this code does
    2. DO NOT use "..." or ". . ." or ellipsis in your summary
    3. Be specific about the actual functionality
    4. Extract 3 concrete technical concepts from the code
    
    OUTPUT FORMAT (strict JSON):
    {
      "summary": "A clear description of what #{filename} does",
      "concepts": ["Concept1", "Concept2", "Concept3"]
    }
    
    BEGIN YOUR ANALYSIS NOW:
    """
    
    case retry_post("#{@base_url}/api/generate", %{
      model: model,
      prompt: prompt,
      format: "json",
      stream: false,
      temperature: 0.7,
      keep_alive: -1
    }, 120_000) do
      {:ok, %Req.Response{status: 200, body: %{"response" => resp_json}}} ->
        Logger.info("Ollama Response [#{model}]: #{resp_json}")
        
        cleaned_json = extract_json(resp_json)
        case Jason.decode(cleaned_json) do
          {:ok, %{"summary" => summary} = decoded} when is_binary(summary) ->
            # Check if response is actually useful
            if String.length(summary) >= 15 and not String.match?(summary, ~r/^[\.\s]+$/) and not String.contains?(summary, "...") do
              {:ok, decoded}
            else
              # Bad response - retry if we have attempts left
              if retries_left > 0 do
                Logger.warning("Ollama returned minimal/ellipsis response: '#{summary}'. Retrying... (#{retries_left} left)")
                :timer.sleep(1500)
                attempt_summarize(content, model, retries_left - 1, file_context)
              else
                Logger.error("Ollama exhausted retries, last response: '#{summary}'")
                {:error, "Poor quality response after all retries"}
              end
            end
          {:error, _} -> 
            if retries_left > 0 do
              Logger.warning("Invalid JSON from Ollama. Retrying... (#{retries_left} left)")
              :timer.sleep(1500)
              attempt_summarize(content, model, retries_left - 1, file_context)
            else
              {:error, "Invalid JSON after all retries"}
            end
          _ ->
            if retries_left > 0 do
              Logger.warning("Unexpected Ollama response format. Retrying... (#{retries_left} left)")
              :timer.sleep(1500)
              attempt_summarize(content, model, retries_left - 1, file_context)
            else
              {:error, "Unexpected response format after all retries"}
            end
        end
      {:error, reason} -> {:error, reason}
      {:ok, other} -> {:error, "Unexpected HTTP response: #{inspect(other)}"}
    end
  end

  # ... extract_json exists here ...
  defp extract_json(str) do
    # 1. Try to find content between ```json and ```
    case Regex.run(~r/```json\s*(.*?)\s*```/s, str) do
      [_, json] -> json
      nil ->
        # 2. Try to find content between ``` and ```
        case Regex.run(~r/```\s*(.*?)\s*```/s, str) do
          [_, json] -> json
          nil ->
            # 3. Try to find the first { and last }
            case Regex.run(~r/(\{.*\})/s, str) do
              [_, json] -> json
              nil -> str # Fallback to original string
            end
        end
    end
  end

  @doc """
  Generates embedding for the given text.
  """
  def embed(text, model \\ "qwen3:0.6b") do
    if Mix.env() == :test do
       {:ok, List.duplicate(0.1, 384)}
    else
      GenServer.call(__MODULE__, {:request, :embedding, fn ->
        case retry_post("#{@base_url}/api/embeddings", %{
          model: model,
          prompt: text
        }, 30_000) do
          {:ok, %Req.Response{status: 200, body: %{"embedding" => vec}}} ->
            {:ok, vec}
          {:error, reason} -> {:error, reason}
          {:ok, other} -> {:error, "Unexpected response: #{inspect(other)}"}
        end
      end}, :infinity)
    end
  end

  defp retry_post(url, body, timeout, retries \\ 3) do
    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, response} -> {:ok, response}
      {:error, %Mint.TransportError{reason: :timeout}} when retries > 0 ->
        Logger.warn("Ollama Bridge: Connection Timeout. Retrying... (#{retries} left)")
        :timer.sleep(2000)
        retry_post(url, body, timeout, retries - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    {:ok, %__MODULE__{
      inference_tokens: @inference_limit,
      embedding_tokens: @embedding_limit,
      inference_queue: :queue.new(),
      embedding_queue: :queue.new()
    }}
  end

  @impl true
  def handle_call({:request, type, func}, from, state) do
    tokens = get_tokens(state, type)
    
    if tokens > 0 do
      # Execute immediately
      new_state = consume_token(state, type)
      execute_request(type, func, from)
      {:noreply, new_state}
    else
      # Queue request
      new_queue = :queue.in({func, from}, get_queue(state, type))
      new_state = update_queue(state, type, new_queue)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:release, type}, state) do
    # 1. Replenish Token
    # state = replenish_token(state, type) # Wait, logic is: release means one finished.
    # So we take next from queue if available.
    
    queue = get_queue(state, type)
    
    case :queue.out(queue) do
      {{:value, {func, from}}, remaining_queue} ->
         # Consume the token effectively by NOT incrementing count (we just passed it to the next guy)
         execute_request(type, func, from)
         {:noreply, update_queue(state, type, remaining_queue)}
         
      {:empty, _} ->
         # No one waiting, restore the token count
         {:noreply, replenish_token(state, type)}
    end
  end
  
  defp execute_request(type, func, from) do
     Task.start(fn ->
        result = func.()
        GenServer.cast(__MODULE__, {:release, type})
        GenServer.reply(from, result)
      end)
  end

  defp get_tokens(state, :inference), do: state.inference_tokens
  defp get_tokens(state, :embedding), do: state.embedding_tokens
  
  defp get_queue(state, :inference), do: state.inference_queue
  defp get_queue(state, :embedding), do: state.embedding_queue
  
  defp consume_token(state, :inference), do: %{state | inference_tokens: state.inference_tokens - 1}
  defp consume_token(state, :embedding), do: %{state | embedding_tokens: state.embedding_tokens - 1}

  defp replenish_token(state, :inference), do: %{state | inference_tokens: state.inference_tokens + 1}
  defp replenish_token(state, :embedding), do: %{state | embedding_tokens: state.embedding_tokens + 1}
  
  defp update_queue(state, :inference, q), do: %{state | inference_queue: q}
  defp update_queue(state, :embedding, q), do: %{state | embedding_queue: q}
end
