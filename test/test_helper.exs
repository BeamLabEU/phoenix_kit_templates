Logger.configure(level: :warning)

Application.put_env(:phoenix_kit_templates, PhoenixKit.Templates.TestEndpoint,
  secret_key_base: String.duplicate("phoenix_kit_templates", 4),
  live_view: [signing_salt: "editor-test"],
  server: false
)

{:ok, _pid} = PhoenixKit.Templates.TestEndpoint.start_link()

ExUnit.start()
