defmodule CMS.RecoveryTest do
  use ExUnit.Case
  alias CMS.{Node, NodeHead, NodeBody, NodeAntenna, DataHead, DataTail}
  alias CMS.Recovery.Hydrator

  test "NodeBody with binary data is Base64 encoded and decoded correctly" do
    # 1. Create a node with compressed binary data
    binary_content = <<0, 1, 2, 3, 255, 219, 157>>
    compressed = :zlib.zip(binary_content)
    
    head = NodeHead.new(UUID.uuid4(), Nx.tensor(Enum.map(1..384, fn _ -> 0.1 end)), "test-v1")
    ledger = DataTail.new("/tmp/test.ex", "hash", "text/plain")
    data_head = %DataHead{summary: "test", concepts: []}
    
    body = NodeBody.new(data_head, binary_content, ledger, :deep)
    # Ensure it's compressed (binary)
    assert is_binary(body.data_body)

    node = Node.new(head, body, %NodeAntenna{})

    # 2. Serialize to JSON (Base64 encoding happens here)
    json = Jason.encode!(node)
    assert String.contains?(json, "data_body_is_base64\":true")
    
    # Verify it's a string in JSON, not raw bytes
    decoded_json = Jason.decode!(json)
    assert is_binary(decoded_json["body"]["data_body"])
    # It should be a valid UTF-8 string (Base64)
    assert String.valid?(decoded_json["body"]["data_body"])

    # 3. Reconstruct using Hydrator
    reconstructed = Hydrator.reconstruct_node(decoded_json)

    # 4. Assertions
    assert reconstructed.body.data_body == compressed
    assert reconstructed.body.data_body == node.body.data_body
    assert NodeBody.decompress(reconstructed.body) == binary_content
  end

  test "NodeHead with spatial_coords tuple is encoded as list and decoded back to tuple" do
    head = NodeHead.new(UUID.uuid4(), Nx.tensor([0.1, 0.2]), "test-v1", 0.35, {1.2, 3.4, 5})
    assert head.spatial_coords == {1.2, 3.4, 5}

    json = Jason.encode!(head)
    assert String.contains?(json, "\"spatial_coords\":[1.2,3.4,5]")

    decoded_json = Jason.decode!(json)
    assert decoded_json["spatial_coords"] == [1.2, 3.4, 5]

    # Use reconstruct_node logic (extracting just the head part)
    # Reconstruct expects a full node_map, so let's wrap it
    node_map = %{
      "id" => head.uuid,
      "head" => decoded_json,
      "body" => %{
        "data_head" => %{"summary" => "s", "concepts" => []},
        "data_body" => nil,
        "data_ledger" => %{
          "physical_symlink" => "p",
          "integrity_hash" => "h",
          "mime_definition" => "m",
          "last_mutation" => DateTime.to_iso8601(DateTime.utc_now())
        }
      },
      "antenna" => %{"gain" => 1.0},
      "tail" => %{}
    }

    reconstructed_node = Hydrator.reconstruct_node(node_map)
    assert reconstructed_node.head.spatial_coords == {1.2, 3.4, 5}
  end
end
