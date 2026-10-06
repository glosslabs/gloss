import gleam/http
import gleam/option.{None, Some}
import gleeunit/should
import gloss/internal/http_forwarded.{Origin} as forwarded

fn cidrs(texts: List(String)) {
  let assert Ok(cidrs) = list_try_map(texts, forwarded.parse_cidr)
  cidrs
}

fn list_try_map(items: List(a), f: fn(a) -> Result(b, Nil)) {
  case items {
    [] -> Ok([])
    [x, ..rest] ->
      case f(x), list_try_map(rest, f) {
        Ok(y), Ok(ys) -> Ok([y, ..ys])
        _, _ -> Error(Nil)
      }
  }
}

pub fn cidr_test() {
  let trusted = cidrs(["10.0.0.0/8", "192.168.1.7", "fd00::/8"])
  forwarded.contains(trusted, "10.20.30.40") |> should.be_true
  forwarded.contains(trusted, "11.0.0.1") |> should.be_false
  forwarded.contains(trusted, "192.168.1.7") |> should.be_true
  forwarded.contains(trusted, "192.168.1.8") |> should.be_false
  forwarded.contains(trusted, "fd12::1") |> should.be_true
  forwarded.contains(trusted, "fe80::1") |> should.be_false
  // IPv4-mapped IPv6 matches the IPv4 block.
  forwarded.contains(trusted, "::ffff:10.1.2.3") |> should.be_true
  forwarded.contains(cidrs(["172.16.0.0/12"]), "172.31.255.255")
  |> should.be_true
  forwarded.contains(cidrs(["172.16.0.0/12"]), "172.32.0.0") |> should.be_false
  forwarded.parse_cidr("10.0.0.0/33") |> should.equal(Error(Nil))
  forwarded.parse_cidr("nope") |> should.equal(Error(Nil))
}

pub fn untrusted_peers_are_taken_at_their_word_test() {
  forwarded.resolve(
    [#("x-forwarded-for", "1.2.3.4"), #("x-forwarded-proto", "https")],
    "203.0.113.9",
    cidrs(["10.0.0.0/8"]),
  )
  |> should.equal(Origin(client_ip: "203.0.113.9", scheme: None, host: None))
}

pub fn x_forwarded_headers_test() {
  let trusted = cidrs(["10.0.0.0/8"])
  forwarded.resolve(
    [
      #("x-forwarded-for", "203.0.113.5, 10.0.0.2"),
      #("x-forwarded-proto", "https"),
      #("x-forwarded-host", "example.com"),
    ],
    "10.0.0.1",
    trusted,
  )
  |> should.equal(Origin(
    client_ip: "203.0.113.5",
    scheme: Some(http.Https),
    host: Some("example.com"),
  ))
}

pub fn spoofed_addresses_on_the_left_are_ignored_test() {
  forwarded.resolve(
    [#("x-forwarded-for", "6.6.6.6, 203.0.113.5")],
    "10.0.0.1",
    cidrs(["10.0.0.0/8"]),
  ).client_ip
  |> should.equal("203.0.113.5")
}

pub fn all_trusted_gives_the_leftmost_test() {
  forwarded.resolve(
    [#("x-forwarded-for", "10.0.0.9, 10.0.0.8")],
    "10.0.0.1",
    cidrs(["10.0.0.0/8"]),
  ).client_ip
  |> should.equal("10.0.0.9")
}

pub fn forwarded_header_test() {
  forwarded.resolve(
    [
      #(
        "forwarded",
        "for=\"[2001:db8::1]:4711\";proto=https;host=example.com, for=10.0.0.2",
      ),
      #("x-forwarded-for", "9.9.9.9"),
    ],
    "10.0.0.1",
    cidrs(["10.0.0.0/8"]),
  )
  |> should.equal(Origin(
    client_ip: "2001:db8::1",
    scheme: Some(http.Https),
    host: Some("example.com"),
  ))
}
