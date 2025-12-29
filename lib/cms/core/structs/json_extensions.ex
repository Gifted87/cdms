defimpl Jason.Encoder, for: Nx.Tensor do
  def encode(tensor, opts) do
    # Convert the high-performance Tensor binary into a simple list of floats
    # so it can be written to the JSON log file.
    list_data = Nx.to_flat_list(tensor)
    Jason.Encode.list(list_data, opts)
  end
end
