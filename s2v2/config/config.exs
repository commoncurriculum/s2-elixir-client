import Config

if Mix.env() == :dev do
  config :oapi_generator,
  default: [
    output: [
      base_module: S2,
      location: "lib/s2",
      default_client: S2.Client,
      operation_subdirectory: "operations",
      schema_subdirectory: "schemas",
      field_casing: :snake
    ],
    ignore: [
      # Data plane operations — these use protobuf/S2S, not JSON
      "read",
      "append",
      "check_tail"
    ]
  ]
end
