defmodule WebAnalytics.Repo.Migrations.CreateFormCaptures do
  use Ecto.Migration

  def change do
    create table(:form_captures) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :pageview_id, references(:pageviews, on_delete: :nilify_all)

      # submitted | abandoned
      add :status, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      add :path, :string
      add :title, :string

      add :form_id, :string
      add :form_name, :string
      add :form_action, :text
      add :form_method, :string
      add :form_selector, :text
      add :form_classes, {:array, :string}, null: false, default: []

      add :field_count, :integer, null: false, default: 0
      add :filled_count, :integer, null: false, default: 0
      add :time_to_first_input_ms, :integer
      add :duration_ms, :integer

      # `fields` keeps per-field metadata (label, type, interaction counts);
      # `data` is the flat name => value map for querying submitted values.
      add :fields, {:array, :map}, null: false, default: []
      add :data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:form_captures, [:site_id, :occurred_at])
    create index(:form_captures, [:site_id, :status, :occurred_at])
    create index(:form_captures, [:site_id, :form_id])
    create index(:form_captures, [:session_id])
  end
end
