import Config

# Licensor public key. Written by `mix ssa.license keygen`.
#
# This is the public half and is meant to be committed — it only verifies
# signatures, it cannot create them. The private half is in
# priv/licensor_private_key, is gitignored, and must never be published: anyone
# holding it can mint keys this build will accept.
config :web_analytics, :license, public_key: "9Ksj/WDlnXkDCvfGGCywtG5CjFUTkFC64KJSThneJ+g="
