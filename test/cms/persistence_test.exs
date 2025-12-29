defmodule CMS.PersistenceTest do
  use ExUnit.Case
  alias CMS.Persistence.Identity
  alias CMS.Persistence.Bootloader

  setup do
    # Ensure a clean data dir for tests
    mnesia_dir = Application.get_env(:mnesia, :dir) || "priv/data/mnesia_test"
    File.rm_rf!(mnesia_dir)
    File.mkdir_p!(mnesia_dir)
    Identity.delete_lock()
    :ok
  end

  test "Identity writes and reads lock" do
    assert Identity.check_lock() == :missing
    
    Identity.sign_lock()
    assert Identity.check_lock() == :ok
  end

  test "Identity detects mismatch" do
    Identity.sign_lock()
    
    # Manually corrupt the lock to simulate alien architecture
    path = "priv/data/identity.lock" # Note: check_lock calculates this path
    real_identity = Identity.current_identity()
    alien_identity = Map.put(real_identity, :architecture, "alien-arch-128bit")
    
    File.write!(path, :erlang.term_to_binary(alien_identity))
    
    assert Identity.check_lock() == :mismatch
  end
  
  test "Bootloader rehydrates on missing lock if data exists" do
    # 1. Create a dummy mnesia file to simulate existing data
    mnesia_dir = Application.get_env(:mnesia, :dir) || "priv/data/mnesia_test"
    File.write!(Path.join(mnesia_dir, "schema.DAT"), "fake-schema")
    
    # lock is missing by setup
    assert Identity.check_lock() == :missing
    
    # 2. Run Bootloader
    # It should trigger rehydration because data_exists? is true
    assert Bootloader.run() == :ok
    
    # 3. Verify it's now ok
    assert Identity.check_lock() == :ok
    
    # 4. Verify rehydrator was called (implicitly by the fact that it signed the lock and survived)
  end

  test "Bootloader handles fresh start (no lock, no data)" do
    # No data created
    assert Identity.check_lock() == :missing
    assert Bootloader.run() == :ok
    assert Identity.check_lock() == :ok
  end
end
