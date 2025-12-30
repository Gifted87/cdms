import Config

# Configure the Cognitive Bus (Phoenix PubSub)
# This enables the "Spreading Activation" mechanism across Semantic Regions.
config :acn_cms, CMS.PubSub,
  adapter: Phoenix.PubSub.PG2,
  pool_size: 1

# CREMS Configuration (Section 8: Necrosis Protocol)
config :cms,
  # Ghost retention period in hours (default: 24 hours)
  crems_ghost_retention_hours: 24,
  # Scavenger scan interval in milliseconds (default: 1 hour)
  crems_scavenger_interval_ms: 3_600_000,
  # EpochLog storage path
  crems_epoch_log_path: "priv/data/crems_epoch_logs"



# Configure Logger for structured auditing (Radical Transparency)
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :node_id, :region_id]

# Import environment specific config
# import_config "#{Mix.env()}.exs"
