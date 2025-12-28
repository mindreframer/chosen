defmodule Chosen.TestConfig do
  @moduledoc """
  Test database connection configuration.
  """

  def db_config do
    [
      hostname: "localhost",
      port: 5432,
      username: "postgres",
      password: "postgres",
      database: "chosen_test"
    ]
  end
end
