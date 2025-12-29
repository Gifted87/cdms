import Config

# Configure the Cognitive Bus (Phoenix PubSub)
# This enables the "Spreading Activation" mechanism across Semantic Regions.
config :acn_cms, CMS.PubSub,
  adapter: Phoenix.PubSub.PG2,
  pool_size: 1



# Configure Logger for structured auditing (Radical Transparency)
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :node_id, :region_id]

# Import environment specific config
# import_config "#{Mix.env()}.exs"
