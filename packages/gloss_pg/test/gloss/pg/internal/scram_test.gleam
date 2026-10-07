import gloss/pg/internal/scram

// The exchange from RFC 7677, section 3.
pub fn rfc_7677_exchange_test() {
  let #(first, client) = scram.client_first("user", "rOprNGfwEbeRWgbNEkqO")
  assert first == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO"

  let server_first =
    "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
  let assert Ok(#(final, expected)) =
    scram.client_final(client, "pencil", server_first)
  assert final
    == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
  assert scram.verify(
    "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=",
    expected,
  )
  assert !scram.verify("v=AAAA", expected)
}

pub fn a_server_nonce_must_extend_ours_test() {
  let #(_, client) = scram.client_first("", "abc")
  assert scram.client_final(client, "pw", "r=xyz,s=c2FsdA==,i=4096")
    == Error(Nil)
}
