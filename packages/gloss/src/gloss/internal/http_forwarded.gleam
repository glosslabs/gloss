//// Who a request really came from when it passed through trusted reverse
//// proxies: the client's address, and the scheme and host it used.

import gleam/http.{type Scheme}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// An address or block of addresses, e.g. `10.0.0.0/8` or `::1`.
pub opaque type Cidr {
  Cidr(bytes: List(Int), bits: Int)
}

pub type Origin {
  Origin(
    client_ip: String,
    /// The scheme the client used, when a trusted proxy said.
    scheme: Option(Scheme),
    /// The host (and port) the client asked for, when a trusted proxy said.
    host: Option(String),
  )
}

pub fn parse_cidr(text: String) -> Result(Cidr, Nil) {
  let #(address, bits) = case string.split_once(string.trim(text), "/") {
    Ok(#(address, bits)) -> #(address, int.parse(bits))
    Error(Nil) -> #(string.trim(text), Error(Nil))
  }
  use bytes <- result.try(ip_bytes(address))
  let max = list.length(bytes) * 8
  case bits {
    Ok(bits) if bits >= 0 && bits <= max -> Ok(Cidr(bytes:, bits:))
    Ok(_) -> Error(Nil)
    Error(Nil) -> Ok(Cidr(bytes:, bits: max))
  }
}

pub fn contains(cidrs: List(Cidr), address: String) -> Bool {
  case ip_bytes(address) {
    Ok(bytes) ->
      list.any(cidrs, fn(cidr) {
        list.length(bytes) == list.length(cidr.bytes)
        && prefix_matches(cidr.bytes, bytes, cidr.bits)
      })
    Error(Nil) -> False
  }
}

fn prefix_matches(network: List(Int), address: List(Int), bits: Int) -> Bool {
  case network, address, bits {
    _, _, 0 -> True
    [n, ..network], [a, ..address], bits if bits >= 8 ->
      n == a && prefix_matches(network, address, bits - 8)
    [n, ..], [a, ..], bits -> {
      let mask = 255 - { int.bitwise_shift_left(1, 8 - bits) - 1 }
      int.bitwise_and(n, mask) == int.bitwise_and(a, mask)
    }
    _, _, _ -> False
  }
}

/// Resolve the request's origin. Forwarding headers count only when the
/// connection came from a trusted proxy; then the client is the rightmost
/// address that isn't a trusted proxy, so addresses a client adds at the
/// left can't be used to pose as someone else. `Forwarded` (RFC 7239) wins
/// over the `X-Forwarded-*` headers.
pub fn resolve(
  headers: List(#(String, String)),
  peer: String,
  trusted: List(Cidr),
) -> Origin {
  case contains(trusted, peer) {
    False -> Origin(client_ip: peer, scheme: None, host: None)
    True -> {
      let elements = forwarded(headers)
      let #(chain, proto, host) = case elements {
        [_, ..] -> #(
          list.filter_map(elements, fn(element) {
            list.key_find(element, "for")
          }),
          first_param(elements, "proto"),
          first_param(elements, "host"),
        )
        [] -> #(
          values(headers, "x-forwarded-for"),
          values(headers, "x-forwarded-proto") |> list.first,
          values(headers, "x-forwarded-host") |> list.first,
        )
      }
      let chain = list.map(chain, strip_port)
      Origin(
        client_ip: client(list.reverse(chain), trusted, peer),
        scheme: case option.from_result(proto) {
          Some(proto) ->
            case string.lowercase(proto) {
              "https" -> Some(http.Https)
              "http" -> Some(http.Http)
              _ -> None
            }
          None -> None
        },
        host: option.from_result(host),
      )
    }
  }
}

/// Walk from the nearest hop outwards, past trusted proxies.
fn client(
  nearest_first: List(String),
  trusted: List(Cidr),
  peer: String,
) -> String {
  case nearest_first {
    [] -> peer
    [address] -> address
    [address, ..rest] ->
      case contains(trusted, address) {
        True -> client(rest, trusted, address)
        False -> address
      }
  }
}

/// Comma-separated values across every header called `name`, in order.
fn values(headers: List(#(String, String)), name: String) -> List(String) {
  headers
  |> list.filter(fn(header) { header.0 == name })
  |> list.flat_map(fn(header) { string.split(header.1, ",") })
  |> list.map(string.trim)
  |> list.filter(fn(value) { value != "" })
}

/// `Forwarded` elements as lowercase-keyed, unquoted parameters.
fn forwarded(
  headers: List(#(String, String)),
) -> List(List(#(String, String))) {
  values(headers, "forwarded")
  |> list.map(fn(element) {
    element
    |> string.split(";")
    |> list.filter_map(fn(pair) {
      case string.split_once(string.trim(pair), "=") {
        Ok(#(key, value)) -> Ok(#(string.lowercase(key), unquote(value)))
        Error(Nil) -> Error(Nil)
      }
    })
  })
}

fn first_param(
  elements: List(List(#(String, String))),
  key: String,
) -> Result(String, Nil) {
  list.find_map(elements, fn(element) { list.key_find(element, key) })
}

fn unquote(value: String) -> String {
  let value = string.trim(value)
  case string.starts_with(value, "\""), string.ends_with(value, "\"") {
    True, True -> value |> string.drop_start(1) |> string.drop_end(1)
    _, _ -> value
  }
}

/// `203.0.113.7:4711` and `[2001:db8::1]:4711` to the bare address.
fn strip_port(address: String) -> String {
  case address {
    "[" <> rest ->
      case string.split_once(rest, "]") {
        Ok(#(ip, _)) -> ip
        Error(Nil) -> address
      }
    _ ->
      case string.split(address, ":") {
        [ip, _port] -> ip
        _ -> address
      }
  }
}

@external(erlang, "gloss@http@server_ffi", "ip_bytes")
fn ip_bytes(text: String) -> Result(List(Int), Nil)
