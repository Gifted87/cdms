
# verification/verify_crems_setup.exs
require Logger

defmodule CREMSSetupVerifier do
  alias CREMS.Core.Logic.IdentityGenerator

  def run do
    Logger.info(">>> Starting CREMS Setup Verification <<<")

    verify_mnesia_table()
    verify_identity_generator()

    Logger.info(">>> Verification Complete <<<")
  end

  defp verify_mnesia_table do
    Logger.info("--- Verifying Mnesia Table Existence ---")
    tables = :mnesia.system_info(:tables)
    
    if :crems_nodes_table in tables do
      Logger.info("[PASS] Table :crems_nodes_table exists.")
      storage_type = :mnesia.table_info(:crems_nodes_table, :storage_type)
      
      # table_info returns the storage type on the *local* node.
      # It returns :ram_copies or :disc_copies or :disc_only_copies.
      if storage_type == :ram_copies do
        Logger.info("[PASS] Storage type is :ram_copies.")
      else
         # Sometimes it returns a list of tuples if querying for all nodes, but here straightforward.
         # Actually checking logic:
         Logger.info("[INFO] Storage type reported: #{inspect(storage_type)}")
         if storage_type == :ram_copies, do: Logger.info("[PASS] Correct."), else: Logger.info("[FAIL] Expected :ram_copies.")
      end
    else
      Logger.error("[FAIL] Table :crems_nodes_table NOT found.")
    end
  end

  defp verify_identity_generator do
    Logger.info("--- Verifying Identity Generator ---")
    
    # Test Case 1: Complete Metadata
    metadata = %{role: "postgres_worker", pid: 4096, user: "postgres", port: 5432}
    expected = "The Postgres Worker process [PID 4096] owned by user 'postgres' listening on port 5432."
    fact = IdentityGenerator.generate_fact(metadata)
    
    if fact == expected do
      Logger.info("[PASS] Full metadata fact generation correct.")
    else
      Logger.error("[FAIL] Expected '#{expected}', got '#{fact}'")
    end

    # Test Case 2: Missing Port
    meta_no_port = %{role: "cron_daemon", pid: 101, user: "root"}
    expected_np = "The Cron Daemon process [PID 101] owned by user 'root'."
    fact_np = IdentityGenerator.generate_fact(meta_no_port)

    if fact_np == expected_np do
      Logger.info("[PASS] Partial metadata fact generation correct.")
    else
      Logger.error("[FAIL] Expected '#{expected_np}', got '#{fact_np}'")
    end
  end
end

# Wait for application to be fully up?
# The script is run with `mix run` which starts the app.
CREMSSetupVerifier.run()
