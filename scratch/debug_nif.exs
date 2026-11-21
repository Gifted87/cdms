# Debug NIF Extraction
path = "lib/cms/ingestion/deterministic_aggregator.ex"
content = File.read!(path)
lang = CMS.Ingestion.CodeGraphEngine.language_from_path(path)

case CMS.Ingestion.CodeGraph.Native.parse_source(lang, content) do
  ast when is_map(ast) ->
    relationships = CMS.Ingestion.CodeGraphEngine.extract_relationships(ast, path)
    IO.puts("Extracted Relationships:")
    Enum.each(relationships, fn r -> IO.inspect(r) end)
  _ ->
    IO.puts("NIF Failed")
end
