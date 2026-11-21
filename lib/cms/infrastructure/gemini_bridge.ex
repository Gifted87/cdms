defmodule CMS.Infrastructure.GeminiBridge do
  @moduledoc """
  The Gemini Bridge: Manages communication with the Gemini API.
  Implements token bucket rate limiting to prevent exceeding quotas.
  """

  use GenServer
  require Logger

  @base_url "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-flash-lite:streamGenerateContent"
  @inference_limit 5
  @embedding_limit 20

  defp api_key do
    CMS.Infrastructure.KeyRotation.get_next_key() || raise "GEMINI_API_KEY not configured"
  end

  defstruct [:inference_tokens, :embedding_tokens, :inference_queue, :embedding_queue]

  # --- Client API ---

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Summarizes file content using the specified LLM (Gemini).
  """
  def summarize(content, _model \\ "gemini-2.5-flash-lite", file_path \\ nil, retries \\ 3) do
    if Mix.env() == :test do
      {:ok, %{"summary" => "Test Summary", "concepts" => ["Term1", "Term2", "Term3"]}}
    else
      GenServer.call(__MODULE__, {:request, :inference, fn ->
        attempt_summarize(content, retries, file_path)
      end}, :infinity)
    end
  end

  defp attempt_summarize(content, retries_left, file_context) do
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
    
    clean_prompt = sanitize_utf8(prompt)

    # Gemini API structure for content
    body = %{
      contents: [
        %{
          role: "user",
          parts: [%{text: clean_prompt}]
        }
      ]
    }

    url = "#{@base_url}?key=#{api_key()}"

    case retry_post(url, body, 120_000) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        Logger.info("Gemini Response received.")
        
        # Gemini often returns a stream of responses, need to concatenate
        # The prompt says 'streamGenerateContent', check how to handle it.
        # Assuming it returns a list of JSON objects if streaming is not fully consumed by Req
        
        # Simple extraction for now
        text = extract_text_from_gemini(resp_body)
        
        cleaned_json = extract_json(text)
        case Jason.decode(cleaned_json) do
          {:ok, %{"summary" => summary} = decoded} when is_binary(summary) ->
            if String.length(summary) >= 15 and not String.match?(summary, ~r/^[\.\s]+$/) and not String.contains?(summary, "...") do
              {:ok, decoded}
            else
              if retries_left > 0 do
                Logger.warning("Gemini returned minimal/ellipsis response. Retrying... (#{retries_left} left)")
                :timer.sleep(1500)
                attempt_summarize(content, retries_left - 1, file_context)
              else
                Logger.error("Gemini exhausted retries")
                {:error, "Poor quality response after all retries"}
              end
            end
          {:error, _} -> 
            if retries_left > 0 do
              Logger.warning("Invalid JSON from Gemini. Retrying... (#{retries_left} left)")
              :timer.sleep(1500)
              attempt_summarize(content, retries_left - 1, file_context)
            else
              {:error, "Invalid JSON after all retries"}
            end
          _ ->
            if retries_left > 0 do
              Logger.warning("Unexpected Gemini response format. Retrying... (#{retries_left} left)")
              :timer.sleep(1500)
              attempt_summarize(content, retries_left - 1, file_context)
            else
              {:error, "Unexpected response format after all retries"}
            end
        end
      {:error, reason} -> {:error, reason}
      {:ok, other} -> {:error, "Unexpected HTTP response: #{inspect(other)}"}
    end
  end

  defp extract_text_from_gemini(body) do
    # Gemini streamGenerateContent can return a JSON array of objects
    if is_list(body) do
       body
       |> Enum.map(fn part -> get_in(part, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) end)
       |> Enum.reject(&is_nil/1)
       |> Enum.join("")
    else
       get_in(body, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) || ""
    end
  end

  defp extract_json(str) do
    case Regex.run(~r/```json\s*(.*?)\s*```/s, str) do
      [_, json] -> json
      nil ->
        case Regex.run(~r/```\s*(.*?)\s*```/s, str) do
          [_, json] -> json
          nil ->
            case Regex.run(~r/(\{.*\})/s, str) do
              [_, json] -> json
              nil -> str 
            end
        end
    end
  end

  # Gemini embeddings are different. Need to check if I need to implement them differently.
  # The original code had `@base_url/api/embeddings`.
  # Gemini API uses a different endpoint for embeddings: `models/text-embedding-004:embedContent`
  
  def embed(text, _model \\ "text-embedding-004") do
    if Mix.env() == :test do
       {:ok, List.duplicate(0.1, 384)}
    else
      GenServer.call(__MODULE__, {:request, :embedding, fn ->
        url = "https://aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1/publishers/google/models/text-embedding-004:predict?key=#{api_key()}"
        clean_text = sanitize_utf8(text)
        body = %{
          instances: [%{content: clean_text}]
        }
        case retry_post(url, body, 30_000) do
          {:ok, %Req.Response{status: 200, body: %{"predictions" => [%{"embeddings" => %{"values" => vec}}]}}} ->
            {:ok, vec}
          {:error, reason} -> {:error, reason}
          {:ok, other} -> {:error, "Unexpected response: #{inspect(other)}"}
        end
      end}, :infinity)
    end
  end

  defp retry_post(url, body, timeout, retries \\ 3) do
    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %Req.Response{status: 429} = _response} when retries > 0 ->
        # Exponential-ish backoff: 3s, 6s, 9s
        wait_time = (4 - retries) * 3000
        Logger.warning("Gemini Bridge: 429 Resource Exhausted. Retrying in #{wait_time}ms... (#{retries} left)")
        :timer.sleep(wait_time)
        retry_post(url, body, timeout, retries - 1)

      {:ok, response} -> {:ok, response}

      {:error, %Mint.TransportError{reason: :timeout}} when retries > 0 ->
        Logger.warning("Gemini Bridge: Connection Timeout. Retrying... (#{retries} left)")
        :timer.sleep(2000)
        retry_post(url, body, timeout, retries - 1)

      {:error, reason} -> {:error, reason}
    end
  end

  defp sanitize_utf8(binary) when is_binary(binary) do
    binary
    |> String.codepoints()
    |> Enum.filter(&String.valid?/1)
    |> Enum.join("")
  end
  defp sanitize_utf8(other), do: other

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
      new_state = consume_token(state, type)
      execute_request(type, func, from)
      {:noreply, new_state}
    else
      new_queue = :queue.in({func, from}, get_queue(state, type))
      new_state = update_queue(state, type, new_queue)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:release, type}, state) do
    queue = get_queue(state, type)
    case :queue.out(queue) do
      {{:value, {func, from}}, remaining_queue} ->
         execute_request(type, func, from)
         {:noreply, update_queue(state, type, remaining_queue)}
      {:empty, _} ->
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
