defmodule Chosen.TestRepo do
  use Ecto.Repo,
    otp_app: :chosen,
    adapter: Ecto.Adapters.Postgres
end
