import gleam/bytes_tree
import gleam/option.{None, Some}
import gloss/internal/pg_protocol as protocol

pub fn decodes_a_data_row_with_a_null_test() {
  let buffer = <<"D":utf8, 16:32, 2:16, 2:32, "hi":utf8, -1:32, "rest":utf8>>
  assert protocol.decode(buffer)
    == Ok(#(protocol.DataRow([Some(<<"hi":utf8>>), None]), <<"rest":utf8>>))
}

pub fn waits_for_the_rest_of_a_message_test() {
  assert protocol.decode(<<"Z":utf8, 5:32>>) == Error(protocol.Incomplete)
  assert protocol.decode(<<"Z":utf8>>) == Error(protocol.Incomplete)
  assert protocol.decode(<<"Z":utf8, 5:32, "I":utf8>>)
    == Ok(#(protocol.ReadyForQuery, <<>>))
}

pub fn decodes_error_fields_test() {
  let body = <<
    "C23505":utf8,
    0,
    "Mduplicate":utf8,
    0,
    "nusers_email_key":utf8,
    0,
    0,
  >>
  let assert Ok(#(protocol.ErrorResponse(fields), <<>>)) =
    protocol.decode(<<"E":utf8, 40:32, body:bits>>)
  assert fields
    == [#("C", "23505"), #("M", "duplicate"), #("n", "users_email_key")]
}

pub fn decodes_sasl_mechanisms_test() {
  let body = <<10:32, "SCRAM-SHA-256-PLUS":utf8, 0, "SCRAM-SHA-256":utf8, 0, 0>>
  assert protocol.decode(<<"R":utf8, 42:32, body:bits>>)
    == Ok(
      #(
        protocol.Authentication(
          protocol.Sasl(["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"]),
        ),
        <<>>,
      ),
    )
}

pub fn a_bad_length_is_malformed_test() {
  assert protocol.decode(<<"Z":utf8, 2:32, 0>>) == Error(protocol.Malformed)
}

pub fn binds_text_binary_and_null_parameters_test() {
  let bind =
    protocol.bind([Some(#(0, <<"42":utf8>>)), Some(#(1, <<1, 2>>)), None])
    |> bytes_tree.to_bit_array
  assert bind
    == <<
      "B":utf8, 34:32, 0, 0, 3:16, 0:16, 1:16, 0:16, 3:16, 2:32, "42":utf8, 2:32,
      1, 2, -1:32, 0:16,
    >>
}
