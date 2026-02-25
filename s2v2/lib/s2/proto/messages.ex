defmodule S2.Proto.Messages do
  @moduledoc false

  use Protox.Define,
    enums_schemas: %{},
    messages_schemas: %{
      S2.V1.StreamPosition => %Protox.MessageSchema{
        name: S2.V1.StreamPosition,
        syntax: :proto3,
        fields: %{
          seq_num:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: 0},
              label: :optional,
              name: :seq_num,
              tag: 1,
              type: :uint64
            ),
          timestamp:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: 0},
              label: :optional,
              name: :timestamp,
              tag: 2,
              type: :uint64
            )
        }
      },
      S2.V1.Header => %Protox.MessageSchema{
        name: S2.V1.Header,
        syntax: :proto3,
        fields: %{
          name:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: ""},
              label: :optional,
              name: :name,
              tag: 1,
              type: :bytes
            ),
          value:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: ""},
              label: :optional,
              name: :value,
              tag: 2,
              type: :bytes
            )
        }
      },
      S2.V1.AppendRecord => %Protox.MessageSchema{
        name: S2.V1.AppendRecord,
        syntax: :proto3,
        fields: %{
          timestamp:
            Protox.Field.new!(
              kind: %Protox.OneOf{parent: :_timestamp},
              label: :proto3_optional,
              name: :timestamp,
              tag: 1,
              type: :uint64
            ),
          headers:
            Protox.Field.new!(
              kind: :unpacked,
              label: :repeated,
              name: :headers,
              tag: 2,
              type: {:message, S2.V1.Header}
            ),
          body:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: ""},
              label: :optional,
              name: :body,
              tag: 3,
              type: :bytes
            )
        }
      },
      S2.V1.AppendInput => %Protox.MessageSchema{
        name: S2.V1.AppendInput,
        syntax: :proto3,
        fields: %{
          records:
            Protox.Field.new!(
              kind: :unpacked,
              label: :repeated,
              name: :records,
              tag: 1,
              type: {:message, S2.V1.AppendRecord}
            ),
          match_seq_num:
            Protox.Field.new!(
              kind: %Protox.OneOf{parent: :_match_seq_num},
              label: :proto3_optional,
              name: :match_seq_num,
              tag: 2,
              type: :uint64
            ),
          fencing_token:
            Protox.Field.new!(
              kind: %Protox.OneOf{parent: :_fencing_token},
              label: :proto3_optional,
              name: :fencing_token,
              tag: 3,
              type: :string
            )
        }
      },
      S2.V1.AppendAck => %Protox.MessageSchema{
        name: S2.V1.AppendAck,
        syntax: :proto3,
        fields: %{
          start:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: nil},
              label: :optional,
              name: :start,
              tag: 1,
              type: {:message, S2.V1.StreamPosition}
            ),
          end:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: nil},
              label: :optional,
              name: :end,
              tag: 2,
              type: {:message, S2.V1.StreamPosition}
            ),
          tail:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: nil},
              label: :optional,
              name: :tail,
              tag: 3,
              type: {:message, S2.V1.StreamPosition}
            )
        }
      },
      S2.V1.SequencedRecord => %Protox.MessageSchema{
        name: S2.V1.SequencedRecord,
        syntax: :proto3,
        fields: %{
          seq_num:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: 0},
              label: :optional,
              name: :seq_num,
              tag: 1,
              type: :uint64
            ),
          timestamp:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: 0},
              label: :optional,
              name: :timestamp,
              tag: 2,
              type: :uint64
            ),
          headers:
            Protox.Field.new!(
              kind: :unpacked,
              label: :repeated,
              name: :headers,
              tag: 3,
              type: {:message, S2.V1.Header}
            ),
          body:
            Protox.Field.new!(
              kind: %Protox.Scalar{default_value: ""},
              label: :optional,
              name: :body,
              tag: 4,
              type: :bytes
            )
        }
      },
      S2.V1.ReadBatch => %Protox.MessageSchema{
        name: S2.V1.ReadBatch,
        syntax: :proto3,
        fields: %{
          records:
            Protox.Field.new!(
              kind: :unpacked,
              label: :repeated,
              name: :records,
              tag: 1,
              type: {:message, S2.V1.SequencedRecord}
            ),
          tail:
            Protox.Field.new!(
              kind: %Protox.OneOf{parent: :_tail},
              label: :proto3_optional,
              name: :tail,
              tag: 2,
              type: {:message, S2.V1.StreamPosition}
            )
        }
      }
    }
end
