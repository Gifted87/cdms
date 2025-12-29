defmodule CMS.DataBodyPayload do
  @moduledoc """
  Defines the polymorphic structure for elements within a CMS.NodeBody.data_body.

  This implements the 'Format ID' (FID) system (Section 2.2.2), ensuring consuming
  Agents can deterministically parse content (e.g., distinguishing executable code
  from descriptive text).
  """

  # ----------------------------------------------------------------------------
  # FID: TEXT
  # ----------------------------------------------------------------------------
  defmodule Text do
    @derive {Jason.Encoder, only: [:type, :content]}
    defstruct type: :text, content: ""
    @type t :: %__MODULE__{type: :text, content: String.t()}
  end

  # ----------------------------------------------------------------------------
  # FID: CODE
  # ----------------------------------------------------------------------------
  defmodule Code do
    @derive {Jason.Encoder, only: [:type, :language, :content]}
    defstruct type: :code, language: :elixir, content: ""
    @type t :: %__MODULE__{type: :code, language: atom(), content: String.t()}
  end

  # ----------------------------------------------------------------------------
  # FID: NUMBER
  # ----------------------------------------------------------------------------
  defmodule Number do
    @derive {Jason.Encoder, only: [:type, :value, :unit]}
    defstruct type: :number, value: 0.0, unit: nil
    @type t :: %__MODULE__{type: :number, value: number(), unit: atom() | nil}
  end

  # ----------------------------------------------------------------------------
  # FID: LINK (External/GM Resource)
  # ----------------------------------------------------------------------------
  defmodule Link do
    @derive {Jason.Encoder, only: [:type, :uri, :description]}
    defstruct type: :link, uri: "", description: nil
    @type t :: %__MODULE__{type: :link, uri: String.t(), description: String.t() | nil}
  end

  # ----------------------------------------------------------------------------
  # FID: OBJECT (Serialized Data)
  # ----------------------------------------------------------------------------
  defmodule Object do
    @derive {Jason.Encoder, only: [:type, :object_type, :data]}
    defstruct type: :object, object_type: nil, data: %{}
    @type t :: %__MODULE__{type: :object, object_type: atom() | nil, data: map()}
  end

  # Union Type for Dialyzer
  @type t :: Text.t() | Code.t() | Number.t() | Link.t() | Object.t()
end
