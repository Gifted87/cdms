# Debug NIF Python
path = "scratch/test_python.py"
content = File.read!(path)
lang = :python

case CMS.Ingestion.CodeGraph.Native.parse_source(lang, content) do
  ast when is_map(ast) ->
    relationships = CMS.Ingestion.CodeGraphEngine.extract_relationships(ast, path)
    IO.puts("Extracted Relationships:")
    Enum.each(relationships, fn r -> IO.inspect(r) end)
    
    IO.puts("\nRaw AST for first few lines:")
    IO.inspect(ast[:children] |> Enum.take(3))
  _ ->
    IO.puts("NIF Failed")
end
