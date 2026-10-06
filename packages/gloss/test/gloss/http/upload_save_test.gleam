import gleam/http
import gleam/http/request
import gleam/int
import gleam/string
import gleeunit/should
import gloss/http/body
import gloss/http/reply
import gloss/http/router
import gloss/http/server
import gloss/http/upload
import http_support.{rendered_body, request}

fn dir() -> String {
  "build/test-uploads/"
  <> int.to_string(system_time())
  <> "-"
  <> int.to_string(unique())
}

/// Saves `photo`, answering with what happened.
fn app(dir: String) {
  let config =
    upload.new(field: "photo", dir:)
    |> upload.max_bytes(10)
    |> upload.accept(["image/png"])
  let routes =
    router.new()
    |> router.post("/", fn(req, _) {
      use result <- upload.save(req, config)
      case result {
        Ok(file) ->
          reply.text(
            200,
            string.join(
              [
                file.name,
                file.path,
                file.filename,
                file.content_type,
                int.to_string(file.size),
              ],
              "|",
            ),
          )
        Error(error) -> upload.error_response(error)
      }
    })
  fn(payload: String, content_type: String) {
    server.handle(
      server.new(routes, Nil),
      request(http.Post, "/")
        |> request.set_header("content-type", content_type)
        |> request.set_body(body.from_string(payload)),
    )
  }
}

fn form(field: String, filename: String, content_type: String, data: String) {
  "--B\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nskip me\r\n"
  <> "--B\r\nContent-Disposition: form-data; name=\""
  <> field
  <> "\"; filename=\""
  <> filename
  <> "\"\r\nContent-Type: "
  <> content_type
  <> "\r\n\r\n"
  <> data
  <> "\r\n--B--\r\n"
}

const multipart = "multipart/form-data; boundary=B"

pub fn saves_the_file_test() {
  let dir = dir()
  let res =
    app(dir)(form("photo", "../../me.png", "image/png", "PNGDATA"), multipart)
  res.status |> should.equal(200)
  let assert [name, path, filename, content_type, size] =
    string.split(rendered_body(res), "|")
  // A random name from the content type, never the client's file name.
  string.ends_with(name, ".png") |> should.be_true
  string.length(name) |> should.equal(20)
  path |> should.equal(dir <> "/" <> name)
  filename |> should.equal("../../me.png")
  content_type |> should.equal("image/png")
  size |> should.equal("7")
  read(path) |> should.equal(Ok("PNGDATA"))
  files(dir) |> should.equal([name])

  upload.delete(path)
  files(dir) |> should.equal([])
}

pub fn refusals_leave_nothing_behind_test() {
  let dir = dir()
  let send = app(dir)
  send(form("photo", "a.gif", "image/gif", "GIF"), multipart).status
  |> should.equal(415)
  send(form("photo", "a.png", "image/png", "MORE THAN TEN BYTES"), multipart).status
  |> should.equal(413)
  // No file chosen, or not in the expected field.
  send(form("photo", "", "application/octet-stream", ""), multipart).status
  |> should.equal(422)
  send(form("other", "a.png", "image/png", "PNG"), multipart).status
  |> should.equal(422)
  send("x", "text/plain").status |> should.equal(415)
  files(dir) |> should.equal([])
}

@external(erlang, "upload_test_ffi", "read")
fn read(path: String) -> Result(String, Nil)

@external(erlang, "upload_test_ffi", "files")
fn files(dir: String) -> List(String)

@external(erlang, "os", "system_time")
fn system_time() -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

type UniqueOption {
  Positive
}

fn unique() -> Int {
  unique_integer([Positive])
}
