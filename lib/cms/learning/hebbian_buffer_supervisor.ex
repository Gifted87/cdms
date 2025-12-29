defmodule CMS.HebbianBufferSupervisor do
  use Supervisor

  @shard_count 32

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      for i <- 0..(@shard_count - 1) do
        %{
          id: :"hebbian_shard_#{i}",
          start: {CMS.RegionalHebbianBuffer, :start_link, [i]},
          restart: :permanent
        }
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
