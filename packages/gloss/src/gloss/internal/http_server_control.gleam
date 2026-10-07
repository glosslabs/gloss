//// The process that owns a running server: the listen socket, the acceptor
//// pool, and a monitor on every open connection.
////
//// Shutting down first calls `on_drain` and, if there is a drain delay,
//// keeps serving until it passes. Then it closes the listen socket, so new
//// connections are refused, asks every connection to drain, and waits for
//// them to finish up to a deadline. Connections still running at the
//// deadline are killed.
////
//// The process traps exits, so a supervisor stopping it, or any linked
//// process exiting, drains the same way before it exits.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/set.{type Set}
import gloss/internal/http_server_tcp.{type ListenSocket, type Socket} as tcp

pub type Config {
  Config(
    interface: String,
    port: Int,
    acceptors: Int,
    /// Milliseconds to wait for connections to drain.
    shutdown_timeout: Int,
    /// Serve one connection; runs in that connection's own process.
    serve: fn(Socket) -> Nil,
    /// Reported when the accept loop hits an error other than the listen
    /// socket closing.
    on_accept_error: fn(String) -> Nil,
    /// The most connections open at once; `None` for no limit. At the cap
    /// acceptors wait, leaving new clients in the listen backlog.
    max_connections: Option(Int),
    /// Called each time the cap is reached.
    on_saturated: fn(Int) -> Nil,
    /// Called as soon as shutdown begins, before the drain delay.
    on_drain: fn() -> Nil,
    /// Milliseconds to keep accepting and serving after shutdown begins,
    /// before the listen socket closes.
    drain_delay: Int,
    /// Called once the server has stopped.
    on_stop: fn() -> Nil,
  )
}

pub type StartError {
  AddressInUse
  InvalidInterface
  ListenFailed(String)
}

pub opaque type Message {
  /// An acceptor asks for a slot before accepting; the reply comes once
  /// the server has room.
  Reserve(granted: Subject(Nil))
  /// A reserved slot was used by this connection.
  Accepted(pid: Pid)
  /// A reserved slot went unused.
  Released
  ConnectionDown(Pid)
  Shutdown(reply: Subject(Result(Nil, Int)))
  /// The drain delay is over: stop accepting and drain connections.
  CloseListener
  DrainDeadline
  Exited(pid: Pid, reason: process.ExitReason)
  Ignore
}

pub type Handle {
  Handle(subject: Subject(Message), port: Int)
}

type State {
  State(
    self: Subject(Message),
    listener: ListenSocket,
    acceptors: Set(Pid),
    connections: Dict(Pid, Monitor),
    shutdown_timeout: Int,
    on_drain: fn() -> Nil,
    drain_delay: Int,
    on_stop: fn() -> Nil,
    /// Shutdown has begun but the drain delay hasn't passed.
    closing: Option(Drain),
    /// The listen socket is closed and connections are draining.
    draining: Option(Drain),
    max_connections: Option(Int),
    on_saturated: fn(Int) -> Nil,
    /// Slots granted to acceptors that haven't accepted yet.
    reserved: Int,
    /// Acceptors held back by the cap, oldest first.
    waiting: List(Subject(Nil)),
  )
}

type Drain {
  Drain(
    reply: Option(Subject(Result(Nil, Int))),
    exit: Option(process.ExitReason),
  )
}

pub fn start(
  config: Config,
) -> Result(actor.Started(Handle), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    process.trap_exits(True)
    case tcp.listen(config.interface, config.port, 1024) {
      Error(error) -> Error(describe(listen_error(error)))
      Ok(listener) -> {
        let port = tcp.port(listener)
        let acceptors =
          list.repeat(Nil, int_max(config.acceptors, 1))
          |> list.map(fn(_) {
            process.spawn(fn() { accept_loop(listener, self, config) })
          })
          |> set.from_list
        let selector =
          process.new_selector()
          |> process.select(self)
          |> process.select_monitors(fn(down) {
            case down {
              process.ProcessDown(pid:, ..) -> ConnectionDown(pid)
              process.PortDown(..) -> Ignore
            }
          })
          |> process.select_trapped_exits(fn(exit) {
            Exited(pid: exit.pid, reason: exit.reason)
          })
        State(
          self:,
          listener:,
          acceptors:,
          connections: dict.new(),
          shutdown_timeout: config.shutdown_timeout,
          on_drain: config.on_drain,
          drain_delay: config.drain_delay,
          on_stop: config.on_stop,
          closing: None,
          draining: None,
          max_connections: config.max_connections,
          on_saturated: config.on_saturated,
          reserved: 0,
          waiting: [],
        )
        |> actor.initialised
        |> actor.selecting(selector)
        |> actor.returning(Handle(subject: self, port:))
        |> Ok
      }
    }
  })
  |> actor.on_message(on_message)
  |> actor.start
}

/// Drain and stop. `Error(n)` when `n` connections had to be killed.
/// `timeout` covers the drain delay and the drain.
pub fn shutdown(handle: Handle, timeout: Int) -> Result(Nil, Int) {
  process.call(handle.subject, timeout + 5000, Shutdown)
}

/// The reason `start` failed, recovered from the initialiser's message.
pub fn start_error(error: actor.StartError) -> StartError {
  case error {
    actor.InitFailed("address in use") -> AddressInUse
    actor.InitFailed("invalid interface") -> InvalidInterface
    actor.InitFailed(reason) -> ListenFailed(reason)
    actor.InitTimeout -> ListenFailed("timed out")
    actor.InitExited(_) -> ListenFailed("exited")
  }
}

fn listen_error(error: tcp.ListenError) -> StartError {
  case error {
    tcp.AddressInUse -> AddressInUse
    tcp.InvalidInterface -> InvalidInterface
    tcp.Other(reason) -> ListenFailed(reason)
  }
}

fn describe(error: StartError) -> String {
  case error {
    AddressInUse -> "address in use"
    InvalidInterface -> "invalid interface"
    ListenFailed(reason) -> reason
  }
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Reserve(granted:) ->
      case state.draining, full(state) {
        // While draining, release at once: the acceptor finds the listener
        // closed and exits.
        Some(_), _ -> {
          process.send(granted, Nil)
          actor.continue(state)
        }
        // Hold the acceptor until a connection closes.
        None, True ->
          actor.continue(
            State(..state, waiting: list.append(state.waiting, [granted])),
          )
        None, False -> {
          process.send(granted, Nil)
          actor.continue(State(..state, reserved: state.reserved + 1))
        }
      }

    Accepted(pid:) -> {
      let monitor = process.monitor(pid)
      case state.draining {
        Some(_) -> tcp.request_drain(pid)
        None -> Nil
      }
      tcp.go(pid)
      let state =
        State(
          ..state,
          reserved: int.max(state.reserved - 1, 0),
          connections: dict.insert(state.connections, pid, monitor),
        )
      let open = dict.size(state.connections)
      case state.max_connections {
        Some(max) if max == open -> state.on_saturated(max)
        _ -> Nil
      }
      actor.continue(state)
    }

    Released ->
      State(..state, reserved: int.max(state.reserved - 1, 0))
      |> release_waiting
      |> actor.continue

    ConnectionDown(pid) ->
      State(..state, connections: dict.delete(state.connections, pid))
      |> release_waiting
      |> finish_if_drained

    Shutdown(reply:) ->
      begin_drain(state, Drain(reply: Some(reply), exit: None))

    CloseListener ->
      case state.closing {
        Some(drain) -> close_and_drain(State(..state, closing: None), drain)
        None -> actor.continue(state)
      }

    Exited(pid:, reason:) ->
      case set.contains(state.acceptors, pid), reason {
        // Acceptors exit normally once the listen socket closes.
        True, process.Normal -> actor.continue(state)
        True, _ -> actor.stop_abnormal("an acceptor crashed")
        // The parent, or another linked process, is going away.
        False, _ -> begin_drain(state, Drain(reply: None, exit: Some(reason)))
      }

    DrainDeadline -> {
      let remaining = dict.size(state.connections)
      dict.keys(state.connections) |> list.each(process.kill)
      stop(state, Error(remaining))
    }

    Ignore -> actor.continue(state)
  }
}

/// Whether every slot is taken by an open connection or a reservation.
fn full(state: State) -> Bool {
  case state.max_connections {
    Some(max) -> dict.size(state.connections) + state.reserved >= max
    None -> False
  }
}

/// Grant a held acceptor a slot, now that there is room.
fn release_waiting(state: State) -> State {
  case state.waiting, full(state) {
    [granted, ..rest], False -> {
      process.send(granted, Nil)
      State(..state, waiting: rest, reserved: state.reserved + 1)
    }
    _, _ -> state
  }
}

fn begin_drain(state: State, drain: Drain) -> actor.Next(State, Message) {
  case state.closing, state.draining {
    // Already shutting down: the first request decides how we stop.
    Some(_), _ | _, Some(_) -> actor.continue(state)
    None, None -> {
      state.on_drain()
      case state.drain_delay {
        0 -> close_and_drain(state, drain)
        delay -> {
          // Keep serving while load balancers notice the server is going.
          process.send_after(state.self, delay, CloseListener)
          actor.continue(State(..state, closing: Some(drain)))
        }
      }
    }
  }
}

fn close_and_drain(state: State, drain: Drain) -> actor.Next(State, Message) {
  tcp.close_listener(state.listener)
  // Held acceptors find the listener closed and exit.
  list.each(state.waiting, process.send(_, Nil))
  let state = State(..state, waiting: [])
  dict.keys(state.connections) |> list.each(tcp.request_drain)
  process.send_after(state.self, state.shutdown_timeout, DrainDeadline)
  State(..state, draining: Some(drain)) |> finish_if_drained
}

fn finish_if_drained(state: State) -> actor.Next(State, Message) {
  case state.draining, dict.is_empty(state.connections) {
    Some(_), True -> stop(state, Ok(Nil))
    _, _ -> actor.continue(state)
  }
}

fn stop(state: State, result: Result(Nil, Int)) -> actor.Next(State, Message) {
  state.on_stop()
  case state.draining {
    Some(Drain(reply: Some(reply), ..)) -> process.send(reply, result)
    _ -> Nil
  }
  case state.draining {
    Some(Drain(exit: Some(process.Abnormal(_)), ..))
    | Some(Drain(exit: Some(process.Killed), ..)) ->
      actor.stop_abnormal("shutdown")
    _ -> actor.stop()
  }
}

fn accept_loop(
  listener: ListenSocket,
  control: Subject(Message),
  config: Config,
) {
  // Wait for a free slot before accepting, so the cap holds however many
  // acceptors there are.
  let granted = process.new_subject()
  process.send(control, Reserve(granted:))
  process.receive_forever(granted)
  case tcp.accept(listener) {
    Ok(socket) -> {
      let serve = config.serve
      let pid =
        process.spawn_unlinked(fn() {
          tcp.await_go()
          serve(socket)
        })
      tcp.controlling_process(socket, pid)
      // The control process monitors the connection, then lets it start.
      process.send(control, Accepted(pid:))
      accept_loop(listener, control, config)
    }
    Error(tcp.Closed) -> Nil
    Error(tcp.Failed(reason)) -> {
      config.on_accept_error(reason)
      // Give the slot back, and back off briefly, e.g. when out of file
      // descriptors.
      process.send(control, Released)
      process.sleep(10)
      accept_loop(listener, control, config)
    }
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
