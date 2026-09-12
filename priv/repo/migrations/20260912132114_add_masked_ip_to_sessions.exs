defmodule WebAnalytics.Repo.Migrations.AddMaskedIpToSessions do
  use Ecto.Migration

  # Only ever the masked form. The full address is masked in the request that
  # carried it and is never written, so there is no column here that could hold
  # one and no backfill that could recover one for the sessions already stored.
  def change do
    alter table(:sessions) do
      add :ip_masked, :string, size: 64
    end
  end
end
