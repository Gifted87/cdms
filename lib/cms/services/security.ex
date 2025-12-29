defmodule CMS.Security do
  @moduledoc """
  Manages Access Control Lists (ACLs) and permission enforcement.

  CRITICAL UPDATE (Gap 11/12): Now supports structured ACL maps for granular control.
  """

  # Pre-defined system roles/IDs that always grant access
  @system_roles ["root", "system"]
  @public_role "public"

  @doc """
  Checks if an Agent ID has permission to perform a WRITE action on a specific structured ACL.
  """
  @spec can_write?(String.t(), map()) :: boolean()
  def can_write?(agent_id, acls) do
    # In a real system, this checks signatures or tokens.
    # For Version 2.0, we check strict membership in the :write list or 'root' privileges.

    write_list = Map.get(acls, :write, [])

    # Agent must be explicitly listed in the write ACLs or be a recognized system role
    Enum.member?(write_list, agent_id) || Enum.member?(@system_roles, agent_id)
  end

  @doc """
  Checks if an Agent ID has permission to perform a READ action on a specific structured ACL.
  """
  @spec can_read?(String.t(), map()) :: boolean()
  def can_read?(agent_id, acls) do
    read_list = Map.get(acls, :read, [])

    # Access is granted if:
    # 1. The node is publicly readable.
    # 2. The agent is explicitly listed in the read ACLs.
    # 3. The agent is a recognized system role (can read anything).
    Enum.member?(read_list, @public_role) || Enum.member?(read_list, agent_id) || Enum.member?(@system_roles, agent_id)
  end
end
