import Config

# ------------------------------------------------------------------------------
# Pillar 3: The Git-Model Infrastructure (Runtime Configuration)
# ------------------------------------------------------------------------------
# This file is executed precisely at boot time.
# It bridges the Semantic Gap between the OS Environment and the BEAM VM.
# ------------------------------------------------------------------------------

# 1. Capture & Resolve Data Directory (The Context Slot)
# Parse .env file if it exists, injecting into System.env
if File.exists?(".env") do
  File.read!(".env")
  |> String.split("\n", trim: true)
  |> Enum.each(fn line ->
    if not String.starts_with?(line, "#") and String.contains?(line, "=") do
      [key, val] = String.split(line, "=", parts: 2)
      # Remove surrounding quotes from the value if present
      val = String.trim(val) |> String.replace(~r/^["']|["']$/, "")
      System.put_env(String.trim(key), val)
    end
  end)
end

# Defaults to ./memory_cartridges/default if not specified
raw_data_dir = System.get_env("ACMS_DATA_DIR") || "memory_cartridges/default"
data_dir = Path.expand(raw_data_dir)

# Ensure the directory exists (Mnesia expects its parent to exist at minimum)
if !File.exists?(data_dir) do
  File.mkdir_p!(data_dir)
end

# 2. Configure Mnesia Location
# Critical: This must happen before Mnesia starts.
# We respect the test environment separation normally handled by Mix,
# but for production/dev running via this config, we use the env var.
if config_env() == :test do
  config :mnesia, dir: 'priv/data/mnesia_test'
else
  mnesia_dir = Path.join(data_dir, "mnesia_store")
  config :mnesia, dir: String.to_charlist(mnesia_dir)
end

# 3. Capture & Parse Port
# Defaults to 4000
port = String.to_integer(System.get_env("ACMS_PORT") || "4000")

# 4. Capture Node Name (Informational for logic, actual node name set by vm.args if release)
node_name = System.get_env("ACMS_NODE_NAME") || "cms"

# 5. Security (Session Secret)
secret_key = System.get_env("ACMS_SECRET") || Base.encode64(:crypto.strong_rand_bytes(32))

# 6. Apply Configuration to Application Environment
config :acn_cms,
  data_root: data_dir,
  node_name: node_name,
  web_port: port,
  secret_key: secret_key,
  llm_provider: System.get_env("LLM_PROVIDER") || "gemini",
  gemini_api_keys: System.get_env("GEMINI_API_KEYS") |> then(fn
    nil -> []
    str -> str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end),
  admin_token: System.get_env("CMS_ADMIN_TOKEN") || "admin_secret"
