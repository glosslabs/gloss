//// What every repository port shares.
////
//// A repository is a process that answers storage messages. The domain
//// defines the messages (see `domain/accounts/user_repository` and
//// `domain/forum/thread_repository`) and sends them; an adapter in
//// `infra/` answers them from Postgres, and the tests answer them from
//// memory. Business rules stay in the domain and storage stays in the
//// adapter, with the message type as the only thing between them.

import gleam/erlang/process.{type Subject}

/// Storage could not answer, e.g. because the database is down.
pub type Unavailable {
  Unavailable(reason: String)
}

/// Where an adapter sends its answer to a message.
pub type Reply(a) =
  Subject(Result(a, Unavailable))

/// Send a message to a repository and wait for its answer.
///
/// Storage failing is not an outcome the domain or its users can act on, so
/// it is not part of any domain result type: it panics, and the HTTP server
/// answers 500 and reports the failure. Business outcomes, such as an email
/// already being taken, are part of the answer instead.
pub fn call(repository: Subject(message), make: fn(Reply(a)) -> message) -> a {
  case process.call(repository, 10_000, make) {
    Ok(answer) -> answer
    Error(Unavailable(reason)) -> panic as { "storage unavailable: " <> reason }
  }
}
