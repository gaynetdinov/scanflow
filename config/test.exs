import Config

# We don't run a server during test. If one is required,
# you enable the server option below.
config :scanflow, ScanflowWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "op/tBNbIiDQnrMCLG0t2YyO165slZ+V7szjvD6B8SEm5UwPzsM+BvlxsiyX5mJ6s",
  server: false

# Print only warnings and errors during test
config :logger, level: :warn

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
