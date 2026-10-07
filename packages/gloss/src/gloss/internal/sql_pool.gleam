//// The connection pool behind `gloss/database/sql`, an OTP actor.
////
//// The pool lends a connection to the calling process, which runs its
//// statements on it directly and then gives it back. Results never pass
//// through the pool process, so it is not a throughput bottleneck.
////
//// The pool owns every connection's socket, so a connection closes when the
//// pool stops. It monitors each borrower and closes the connection a dead
//// borrower held, because the borrower may have died mid-statement.
//// Connections are opened in helper processes, so a slow connect never
//// blocks other checkouts, and are then handed to the pool.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Name, type Pid, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string

/// A connection on loan to one process.
pub type Lease(conn) {
  Lease(id: Int, connection: conn)
}

/// What the pool needs to know about a connection.
pub type Ops(conn, error) {
  Ops(
    connect: fn() -> Result(conn, error),
    /// Cheap check, without a round trip, that an idle connection is usable.
    alive: fn(conn) -> Bool,
    /// Make `pid` the owner of the connection's socket.
    transfer: fn(conn, Pid) -> Nil,
    close: fn(conn) -> Nil,
    /// The error for a `connect` that panicked.
    crashed: fn(String) -> error,
  )
}

pub type Message(conn, error) {
  Checkout(caller: Pid, reply: Subject(Result(Lease(conn), error)))
  Cancel(reply: Subject(Result(Lease(conn), error)))
  /// Give a lease back. A connection that may be mid-statement or broken is
  /// returned with `reuse: False` and closed.
  Checkin(id: Int, reuse: Bool)
  Connected(Result(conn, error))
  Down(process.Down)
  /// Anything else, such as the `ETS-TRANSFER` a driver's `transfer` may
  /// cause. Discarded.
  Other
  Shutdown
}

type Waiter(conn, error) {
  Waiter(caller: Pid, reply: Subject(Result(Lease(conn), error)))
}

type Loan(conn) {
  Loan(connection: conn, monitor: Monitor)
}

type State(conn, error) {
  State(
    self: Pid,
    inbox: Subject(Message(conn, error)),
    ops: Ops(conn, error),
    size: Int,
    idle: List(Lease(conn)),
    leased: Dict(Int, Loan(conn)),
    connecting: Int,
    /// Oldest first.
    waiting: List(Waiter(conn, error)),
    next_id: Int,
  )
}

pub fn start(
  ops: Ops(conn, error),
  size: Int,
  name: Name(Message(conn, error)),
) -> Result(actor.Started(Subject(Message(conn, error))), actor.StartError) {
  actor.new_with_initialiser(1000, fn(inbox) {
    let selector =
      process.new_selector()
      |> process.select(inbox)
      |> process.select_monitors(Down)
      |> process.select_other(fn(_) { Other })
    State(
      self: process.self(),
      inbox:,
      ops:,
      size:,
      idle: [],
      leased: dict.new(),
      connecting: 0,
      waiting: [],
      next_id: 1,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(inbox)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// Borrow a connection, waiting up to `timeout` milliseconds.
pub fn checkout(
  pool: Subject(Message(conn, error)),
  timeout: Int,
  unavailable unavailable: error,
  timed_out timed_out: error,
) -> Result(Lease(conn), error) {
  let reply = process.new_subject()
  case try_send(pool, Checkout(process.self(), reply)) {
    False -> Error(unavailable)
    True ->
      case process.receive(reply, timeout) {
        Ok(outcome) -> outcome
        Error(Nil) -> {
          // Forget us, then give back a lease that arrived meanwhile.
          let _ = try_send(pool, Cancel(reply))
          case process.receive(reply, 0) {
            Ok(Ok(lease)) -> checkin(pool, lease, True)
            _ -> Nil
          }
          Error(timed_out)
        }
      }
  }
}

pub fn checkin(
  pool: Subject(Message(conn, error)),
  lease: Lease(conn),
  reuse: Bool,
) -> Nil {
  let _ = try_send(pool, Checkin(lease.id, reuse))
  Nil
}

pub fn shutdown(pool: Subject(Message(conn, error))) -> Nil {
  let _ = try_send(pool, Shutdown)
  Nil
}

// --- Inside the actor --------------------------------------------------------

fn handle(
  state: State(conn, error),
  message: Message(conn, error),
) -> actor.Next(State(conn, error), Message(conn, error)) {
  case message {
    Checkout(caller:, reply:) ->
      actor.continue(lend(state, Waiter(caller:, reply:)))

    Cancel(reply) ->
      actor.continue(
        State(
          ..state,
          waiting: list.filter(state.waiting, fn(w) { w.reply != reply }),
        ),
      )

    Checkin(id:, reuse:) ->
      case dict.get(state.leased, id) {
        Error(Nil) -> actor.continue(state)
        Ok(loan) -> {
          process.demonitor_process(loan.monitor)
          let state = State(..state, leased: dict.delete(state.leased, id))
          case reuse {
            True -> actor.continue(release(state, Lease(id, loan.connection)))
            False -> {
              state.ops.close(loan.connection)
              actor.continue(refill(state))
            }
          }
        }
      }

    Connected(Ok(connection)) -> {
      let lease = Lease(state.next_id, connection)
      let state =
        State(
          ..state,
          connecting: state.connecting - 1,
          next_id: state.next_id + 1,
        )
      actor.continue(release(state, lease))
    }

    Connected(Error(error)) -> {
      let state = State(..state, connecting: state.connecting - 1)
      case state.waiting {
        [waiter, ..rest] -> {
          process.send(waiter.reply, Error(error))
          actor.continue(State(..state, waiting: rest))
        }
        [] -> actor.continue(state)
      }
    }

    Down(process.ProcessDown(monitor:, ..)) -> {
      let dead =
        dict.to_list(state.leased)
        |> list.find(fn(entry) { { entry.1 }.monitor == monitor })
      case dead {
        Error(Nil) -> actor.continue(state)
        Ok(#(id, loan)) -> {
          state.ops.close(loan.connection)
          State(..state, leased: dict.delete(state.leased, id))
          |> refill
          |> actor.continue
        }
      }
    }

    Down(process.PortDown(..)) | Other -> actor.continue(state)

    Shutdown -> {
      list.each(state.idle, fn(lease) { state.ops.close(lease.connection) })
      dict.each(state.leased, fn(_, loan) { state.ops.close(loan.connection) })
      actor.stop()
    }
  }
}

/// Serve a caller from the idle list, by opening a connection, or by
/// queueing them until a connection is given back.
fn lend(
  state: State(conn, error),
  waiter: Waiter(conn, error),
) -> State(conn, error) {
  case state.idle {
    [lease, ..rest] ->
      case state.ops.alive(lease.connection) {
        True -> hand_over(State(..state, idle: rest), lease, waiter)
        False -> {
          state.ops.close(lease.connection)
          lend(State(..state, idle: rest), waiter)
        }
      }
    [] -> {
      let state = State(..state, waiting: list.append(state.waiting, [waiter]))
      case open(state) + state.connecting < state.size {
        True -> connect(state)
        False -> state
      }
    }
  }
}

/// A connection became free: give it to the oldest waiter, or keep it.
fn release(
  state: State(conn, error),
  lease: Lease(conn),
) -> State(conn, error) {
  case state.waiting {
    [waiter, ..rest] -> hand_over(State(..state, waiting: rest), lease, waiter)
    [] -> State(..state, idle: [lease, ..state.idle])
  }
}

/// Capacity freed up: open a connection for a waiter who has none coming.
fn refill(state: State(conn, error)) -> State(conn, error) {
  case list.length(state.waiting) > state.connecting {
    True -> connect(state)
    False -> state
  }
}

fn hand_over(
  state: State(conn, error),
  lease: Lease(conn),
  waiter: Waiter(conn, error),
) -> State(conn, error) {
  let monitor = process.monitor(waiter.caller)
  process.send(waiter.reply, Ok(lease))
  State(
    ..state,
    leased: dict.insert(state.leased, lease.id, Loan(lease.connection, monitor)),
  )
}

fn connect(state: State(conn, error)) -> State(conn, error) {
  let State(self:, inbox:, ops:, ..) = state
  process.spawn_unlinked(fn() {
    let result = case rescue(ops.connect) {
      Ok(Ok(connection)) -> {
        ops.transfer(connection, self)
        Ok(connection)
      }
      Ok(Error(error)) -> Error(error)
      Error(reason) -> Error(ops.crashed(reason))
    }
    process.send(inbox, Connected(result))
  })
  State(..state, connecting: state.connecting + 1)
}

fn open(state: State(conn, error)) -> Int {
  list.length(state.idle) + dict.size(state.leased)
}

fn rescue(work: fn() -> a) -> Result(a, String) {
  rescue_crash(work) |> result.map_error(describe_crash)
}

type Crash

@external(erlang, "gloss@database@sql_ffi", "rescue")
fn rescue_crash(work: fn() -> a) -> Result(a, Crash)

@external(erlang, "erlang", "element")
fn element(index: Int, tuple: Crash) -> b

/// The reason of an `{crash, Class, Reason, Stack}` tuple.
fn describe_crash(crash: Crash) -> String {
  string.inspect(element(3, crash))
}

@external(erlang, "gloss@database@sql_ffi", "try_send")
fn try_send(subject: Subject(message), message: message) -> Bool
