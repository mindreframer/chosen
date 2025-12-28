import Config

if config_env() == :test do
  config :chosen, Chosen.TestRepo,
    hostname: "localhost",
    port: 5432,
    username: "postgres",
    password: "postgres",
    database: "chosen_test",
    pool: Ecto.Adapters.SQL.Sandbox
end
