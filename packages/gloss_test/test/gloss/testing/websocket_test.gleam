import gleam/option.{None}
import gloss/http/router
import gloss/http/server
import gloss/http/websocket as ws
import gloss/testing/websocket

fn start() -> #(server.Server, Int) {
  let routes =
    router.new()
    |> router.get("/echo", fn(req, _) {
      ws.new(
        on_init: fn(_) { #(Nil, None) },
        on_message: fn(state, conn, message) {
          case message {
            ws.Text("bye") -> ws.close(4000, "bye then")
            ws.Text(text) -> {
              let _ = ws.send_text(conn, text)
              ws.continue(state)
            }
            ws.Binary(data) -> {
              let _ = ws.send_binary(conn, data)
              ws.continue(state)
            }
            ws.Custom(_) -> ws.continue(state)
          }
        },
        on_close: fn(_, _) { Nil },
      )
      |> ws.upgrade(req)
    })
  let assert Ok(srv) = server.new(routes, Nil) |> server.port(0) |> server.start
  #(srv, server.port_of(srv))
}

pub fn a_conversation_test() {
  let #(srv, port) = start()
  let assert Ok(client) = websocket.connect(port, "/echo", [])
  assert websocket.header(client, "upgrade") == Ok("websocket")
  let assert Ok(Nil) = websocket.send_text(client, "hello")
  assert websocket.receive(client, 1000) == Ok(websocket.Text("hello"))
  let assert Ok(Nil) = websocket.send_binary(client, <<1, 2, 3>>)
  assert websocket.receive(client, 1000) == Ok(websocket.Binary(<<1, 2, 3>>))
  let assert Ok(Nil) = websocket.send_ping(client, <<"hi":utf8>>)
  assert websocket.receive(client, 1000) == Ok(websocket.Pong(<<"hi":utf8>>))
  let _ = server.shutdown(srv)
}

pub fn fragments_and_closing_test() {
  let #(srv, port) = start()
  let assert Ok(client) = websocket.connect(port, "/echo", [])
  let assert Ok(Nil) = websocket.send_frame(client, False, 1, <<"hel":utf8>>)
  let assert Ok(Nil) = websocket.send_frame(client, True, 0, <<"lo":utf8>>)
  assert websocket.receive(client, 1000) == Ok(websocket.Text("hello"))
  let assert Ok(Nil) = websocket.send_text(client, "bye")
  assert websocket.receive(client, 1000)
    == Ok(websocket.Close(4000, "bye then"))
  let assert Ok(Nil) = websocket.send_close(client, 4000, "")
  assert websocket.wait_closed(client, 1000)
  let _ = server.shutdown(srv)
}

pub fn nothing_arriving_times_out_test() {
  let #(srv, port) = start()
  let assert Ok(client) = websocket.connect(port, "/echo", [])
  assert websocket.receive(client, 50) == Error(websocket.Timeout)
  websocket.disconnect(client)
  let _ = server.shutdown(srv)
}

pub fn a_refused_upgrade_reports_its_status_test() {
  let #(srv, port) = start()
  assert websocket.connect(port, "/nowhere", [])
    == Error(websocket.Refused(404))
  assert websocket.connect(port, "/echo", [#("origin", "https://evil.example")])
    == Error(websocket.Refused(403))
  let _ = server.shutdown(srv)
}
