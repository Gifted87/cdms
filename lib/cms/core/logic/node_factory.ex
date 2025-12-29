defmodule CMS.NodeFactory do
  @moduledoc """
  Responsible for enforcing Content-Addressable Memory (CAM) principles.

  The Node ID is derived from a SHA-256 hash of the canonical JSON representation
  of the DataHead, DataBody, and Provenance Metadata. This ensures that
  identical knowledge maps to the same address.
  """

  alias CMS.NodeBody

  @doc """
  Derives a content-addressable ID for a new CMS Node.

  This ID is a hash of the NodeBody (Truth) and Provenance.
  We specifically exclude dynamic fields (like DataTail.salience_score or Edges)
  because the Identity of the node should not change just because it gained a new link.
  """
  @spec derive_content_addressable_id(NodeBody.t(), map()) :: String.t()
  def derive_content_addressable_id(%NodeBody{} = body, provenance_metadata) do
    # 1. Extract the "Truth" components.
    # We strictly use DataHead and DataBody.
    # DataTail is excluded from the ID hash because relationships (Edges) evolve
    # (Neuroplasticity), but the Node's fundamental "Fact" remains constant.
    truth_component = %{
      data_head: body.data_head,
      data_body: body.data_body
    }

    # 2. Canonical Serialization of Truth.
    # sort_keys: true is CRITICAL. {a:1, b:2} must hash strictly equal to {b:2, a:1}.
    canonical_truth_json = Jason.encode!(truth_component, sort_keys: true)

    # 3. Canonical Serialization of Provenance.
    # This ensures that if the same Fact comes from a different Source context,
    # it *might* be treated as a distinct node (depending on ingestion logic),
    # or merged. The ACN Whitepaper suggests Provenance is part of Identity.
    canonical_provenance_json = Jason.encode!(provenance_metadata, sort_keys: true)

    # 4. Concatenate and Hash.
    content_stream = canonical_truth_json <> canonical_provenance_json

    :crypto.hash(:sha256, content_stream)
    |> Base.encode16(case: :lower)
  end
end
