defmodule WebAnalytics.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :pageview_id, references(:pageviews, on_delete: :nilify_all)

      # click | outbound | download | mailto | tel | rage_click | custom
      add :type, :string, null: false
      add :name, :string
      add :occurred_at, :utc_datetime_usec, null: false

      add :path, :string
      add :title, :string

      # Element identity. `classes` is an array so the dashboard can segregate
      # clicks by any single class without parsing the raw attribute.
      add :tag, :string
      add :el_id, :string
      add :classes, {:array, :string}, null: false, default: []
      add :class_raw, :text
      add :el_name, :string
      add :el_role, :string
      add :el_type, :string
      add :text, :text
      add :selector, :text
      add :data_attrs, :map, null: false, default: %{}

      add :href, :text
      add :href_host, :string
      add :href_path, :text
      add :outbound, :boolean, null: false, default: false
      add :new_tab, :boolean, null: false, default: false

      # Captured on mousedown for outbound clicks, so the trigger is recorded
      # even when the browser tears the page down before a click fires.
      add :trigger, :string

      add :viewport_x, :integer
      add :viewport_y, :integer
      add :page_x, :integer
      add :page_y, :integer
      add :scroll_pct, :integer
      add :ms_since_pageview, :integer

      add :meta, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:events, [:site_id, :occurred_at])
    create index(:events, [:site_id, :type, :occurred_at])
    create index(:events, [:site_id, :el_id])
    create index(:events, [:site_id, :outbound, :href_host])
    create index(:events, [:session_id])
    create index(:events, [:pageview_id])

    execute "CREATE INDEX events_classes_idx ON events USING GIN (classes)",
            "DROP INDEX events_classes_idx"
  end
end
