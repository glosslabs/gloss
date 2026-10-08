import gleam/http
import gleam/option.{None, Some}
import gleeunit/should
import gloss/sentry/internal/dsn

pub fn hosted_dsn_test() {
  dsn.parse("https://abc@o1.ingest.sentry.io/42")
  |> should.equal(
    Ok(dsn.Dsn(http.Https, "o1.ingest.sentry.io", None, "", "abc", "42")),
  )
  let assert Ok(parsed) = dsn.parse("https://abc@o1.ingest.sentry.io/42")
  dsn.envelope_path(parsed) |> should.equal("/api/42/envelope/")
}

pub fn self_hosted_with_secret_port_and_prefix_test() {
  dsn.parse("https://abc:secret@sentry.example.com:9000/prefix/7")
  |> should.equal(
    Ok(dsn.Dsn(
      http.Https,
      "sentry.example.com",
      Some(9000),
      "/prefix",
      "abc",
      "7",
    )),
  )
  let assert Ok(parsed) =
    dsn.parse("https://abc:secret@sentry.example.com:9000/prefix/7")
  dsn.envelope_path(parsed) |> should.equal("/prefix/api/7/envelope/")
}

pub fn http_scheme_test() {
  let assert Ok(parsed) = dsn.parse("http://abc@localhost/1")
  parsed.scheme |> should.equal(http.Http)
}

pub fn errors_test() {
  dsn.parse("not a url") |> should.be_error
  dsn.parse("ftp://abc@host/1") |> should.equal(Error(dsn.MissingScheme))
  dsn.parse("https://host/1") |> should.equal(Error(dsn.MissingPublicKey))
  dsn.parse("https://:secret@host/1")
  |> should.equal(Error(dsn.MissingPublicKey))
  dsn.parse("https://abc@host/") |> should.equal(Error(dsn.MissingProjectId))
  dsn.parse("https://abc@host") |> should.equal(Error(dsn.MissingProjectId))
}
