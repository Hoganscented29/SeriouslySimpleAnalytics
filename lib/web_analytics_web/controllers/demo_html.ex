defmodule WebAnalyticsWeb.DemoHTML do
  @moduledoc """
  Templates for the demo site. Rendered without the dashboard layout so the
  pages look like an ordinary tracked third-party site.
  """
  use WebAnalyticsWeb, :html

  embed_templates "demo_html/*"

  attr :site_key, :string, required: true
  attr :title, :string, required: true
  attr :active, :string, default: nil
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title}</title>
        <!-- The tracker. data-debug logs every beacon to the console. -->
        <script src={~p"/wa.js"} data-site={@site_key} data-debug="true" defer>
        </script>
        <style>
          * { box-sizing: border-box; }
          body { margin: 0; font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                 color: #16181d; background: #fbfbfd; }
          header { border-bottom: 1px solid #e4e6eb; background: #fff; position: sticky; top: 0; z-index: 10; }
          nav { max-width: 760px; margin: 0 auto; padding: 14px 20px; display: flex; gap: 18px; align-items: center; }
          nav a { color: #16181d; text-decoration: none; font-weight: 500; }
          nav a.active { color: #5b4ee5; }
          nav .spacer { flex: 1; }
          main { max-width: 760px; margin: 0 auto; padding: 32px 20px 80px; }
          h1 { font-size: 30px; margin: 0 0 8px; letter-spacing: -0.02em; }
          h2 { font-size: 19px; margin: 36px 0 10px; letter-spacing: -0.01em; }
          p  { color: #4a4f5c; }
          .btn { display: inline-block; padding: 9px 16px; border-radius: 8px; border: 1px solid #d7d9e0;
                 background: #fff; color: #16181d; font-size: 14px; font-weight: 500; cursor: pointer;
                 text-decoration: none; }
          .btn-primary { background: #5b4ee5; border-color: #5b4ee5; color: #fff; }
          .row { display: flex; gap: 10px; flex-wrap: wrap; margin: 18px 0; }
          .card { background: #fff; border: 1px solid #e4e6eb; border-radius: 12px; padding: 20px; margin: 16px 0; }
          .muted { color: #8a90a0; font-size: 13px; }
          label { display: block; font-size: 13px; font-weight: 500; margin: 14px 0 5px; }
          input[type=text], input[type=email], input[type=password], input[type=tel], select, textarea {
            width: 100%; padding: 9px 11px; border: 1px solid #d7d9e0; border-radius: 8px; font-size: 14px;
            font-family: inherit; background: #fff; }
          .check { display: flex; align-items: center; gap: 8px; margin: 10px 0; font-size: 14px; }
          .check input { margin: 0; }
          .filler { padding: 48px 0; border-bottom: 1px dashed #e4e6eb; }
        </style>
      </head>
      <body>
        <header>
          <nav>
            <a href={~p"/demo"} class={@active == "home" && "active"}>Acme</a>
            <a href={~p"/demo/pricing"} class={@active == "pricing" && "active"}>Pricing</a>
            <a href={~p"/demo/docs"} class={@active == "docs" && "active"}>Docs</a>
            <span class="spacer"></span>
            <a href={~p"/dashboard"} class="muted">Dashboard →</a>
          </nav>
        </header>
        <main>
          {render_slot(@inner_block)}
        </main>
      </body>
    </html>
    """
  end
end
