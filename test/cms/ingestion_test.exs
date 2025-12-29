defmodule CMS.IngestionTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias CMS.Ingestion.{MimeGuard, Shredder}
  alias CMS.Web.Router

  @opts Router.init([])

  describe "MimeGuard" do
    test "allows valid extensions" do
      files = ["test.txt", "code.ex", "data.json"]
      for f <- files do
        path = Path.join(System.tmp_dir!(), f)
        File.write!(path, "content")
        assert MimeGuard.check(path) == :ok
        File.rm(path)
      end
    end

    test "rejects invalid extensions" do
      # We don't need to create the file if it checks extension first, 
      # but if check/1 checks content immediately after, we might get ENOENT or error chain.
      # MimeGuard.check calls check_extension then check_content.
      # But check_content opens the file.
      # If extension fails, check_content is NOT called (SHORT CIRCUIT in `with`).
      # So we can pass non-existent files for invalid extensions.
      assert {:error, {:unsupported_extension, ".exe"}} = MimeGuard.check("virus.exe")
      assert {:error, {:unsupported_extension, ".png"}} = MimeGuard.check("image.png")
    end
    
    test "detects binary content via null byte" do
       # Create a temp file with binary content
       path = Path.join(System.tmp_dir!(), "binary_check.txt")
       File.write!(path, <<0, 1, 2, 3>>)
       
       assert {:error, :binary_file} = MimeGuard.check(path)
       File.rm(path)
    end
  end

  describe "Shredder" do
    test "shreds text with overlap" do
      text = String.duplicate("a", 1500)
      chunks = Shredder.shred(text, :text)
      
      assert length(chunks) > 1
      first_chunk = Enum.at(chunks, 0)
      second_chunk = Enum.at(chunks, 1)
      
      # Target 1000, Overlap 200 (20%)
      # First chunk should be ~1000
      assert String.length(first_chunk.content) == 1000
      
      # Verify overlap: End of chunk 0 should match start of chunk 1
      overlap_len = 200
      overlap_text = String.slice(first_chunk.content, -overlap_len, overlap_len)
      assert String.starts_with?(second_chunk.content, overlap_text)
    end

    test "shreds code by lines" do
      # Create 100 lines of code
      lines = Enum.map(1..100, fn i -> "line #{i}" end)
      code = Enum.join(lines, "\n")
      
      chunks = Shredder.shred(code, :code)
      assert length(chunks) > 1
      
      first_chunk = Enum.at(chunks, 0)
      
      # Check line counts in metadata if available or infer from content
      # Shredder returns %{lines: Range}
      assert first_chunk.lines == 1..50
      
      # Second chunk should start at 50 - 5 + 1 = 46
      second_chunk = Enum.at(chunks, 1)
      assert second_chunk.lines == 46..95
    end
  end

  describe "Web Ingestion API" do
    test "POST /api/v1/ingest/blob accepts text" do
      conn = conn(:post, "/api/v1/ingest/blob", %{
        "text" => "This is a test blob.",
        "metadata" => %{"filename" => "test_blob.txt"}
      })
      
      conn = Router.call(conn, @opts)
      
      assert conn.status == 202
      assert Jason.decode!(conn.resp_body)["status"] == "accepted"
      
      # Wait a bit for async task although we aren't asserting on side effects here
      # just API contract.
    end
    
    test "POST /api/v1/ingest/upload accepts zip" do
       # Create dummy zip
       zip_path = Path.join(System.tmp_dir!(), "test_upload.zip")
       {:ok, _} = :zip.create(String.to_charlist(zip_path), [{'test.txt', "hello world"}])
       
       upload = %Plug.Upload{
         path: zip_path,
         filename: "test_upload.zip",
         content_type: "application/zip"
       }
       
       conn = conn(:post, "/api/v1/ingest/upload", %{"file" => upload})
       conn = Router.call(conn, @opts)
       
       assert conn.status == 202
       assert Jason.decode!(conn.resp_body)["type"] == "zip"
       
       File.rm(zip_path)
    end
  end
end
