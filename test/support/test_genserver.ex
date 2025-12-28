defmodule Chosen.TestGenServer do
  @moduledoc """
  A simple GenServer for testing Chosen.

  Features:
  - Can be registered globally
  - Responds to ping messages
  - Can be instructed to crash
  - Tracks start count in ETS
  """
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    # Track that this instance started
    table = Keyword.get(opts, :track_table)

    if table do
      :ets.update_counter(table, :start_count, 1, {:start_count, 0})
    end

    {:ok, %{opts: opts, started_at: System.monotonic_time()}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:crash, _from, _state) do
    raise "Intentional crash for testing"
  end

  # Helper functions for tests
  def ping(server) do
    GenServer.call(server, :ping)
  end

  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  def crash(server) do
    GenServer.call(server, :crash)
  end
end
