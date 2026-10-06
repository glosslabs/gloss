import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleeunit/should
import gloss/http/body
import gloss/http/reply
import http_support.{request}

fn decoder() {
  use title <- decode.field("title", decode.string)
  decode.success(title)
}

fn post(content_type: String, payload: String) {
  request(http.Post, "/")
  |> request.set_header("content-type", content_type)
  |> request.set_body(body.from_string(payload))
}

fn run(req) {
  use title <- body.json(req, decoder())
  reply.text(200, title)
}

pub fn json_test() {
  let res = run(post("application/json; charset=utf-8", "{\"title\":\"x\"}"))
  res.status |> should.equal(200)
  http_support.body(res) |> should.equal("x")
}

pub fn json_wrong_content_type_test() {
  run(post("text/plain", "{}")).status |> should.equal(415)
}

pub fn json_invalid_test() {
  run(post("application/json", "{nope")).status |> should.equal(400)
}

pub fn json_decode_errors_test() {
  let res = run(post("application/json", "{\"title\":1}"))
  res.status |> should.equal(422)
  http_support.body(res)
  |> should.equal(
    "{\"error\":\"unprocessable content\",\"errors\":[\"title: expected String, found Int\"]}",
  )
}

pub fn text_test() {
  let res = {
    use text <- body.text(post("text/plain", "hello"))
    reply.text(200, text)
  }
  http_support.body(res) |> should.equal("hello")
}
