//// The thread repository, answered from memory, for tests.

import domain/forum/thread.{type Thread, Post, Thread}
import domain/forum/thread_repository.{
  type Message, type ThreadRepository, AddPost, Get, Open, Recent,
}
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/order
import gleam/otp/actor
import gleam/time/timestamp

type State {
  State(next_thread: Int, next_post: Int, threads: Dict(Int, Thread))
}

pub fn start() -> ThreadRepository {
  let assert Ok(started) =
    actor.new(State(next_thread: 1, next_post: 1, threads: dict.new()))
    |> actor.on_message(answer)
    |> actor.start
  started.data
}

fn answer(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Open(thread: new, reply:) -> {
      let post =
        Post(
          id: state.next_post,
          author_id: new.author_id,
          body: new.body,
          at: new.at,
        )
      let created =
        Thread(
          id: state.next_thread,
          title: new.title,
          posts: [post],
          last_activity: new.at,
        )
      process.send(reply, Ok(created))
      actor.continue(State(
        next_thread: state.next_thread + 1,
        next_post: state.next_post + 1,
        threads: dict.insert(state.threads, created.id, created),
      ))
    }
    AddPost(post: new, reply:) ->
      case dict.get(state.threads, new.thread_id) {
        Error(Nil) -> {
          process.send(reply, Ok(option.None))
          actor.continue(state)
        }
        Ok(found) -> {
          let post =
            Post(
              id: state.next_post,
              author_id: new.author_id,
              body: new.body,
              at: new.at,
            )
          let updated =
            Thread(
              ..found,
              posts: list.append(found.posts, [post]),
              last_activity: new.at,
            )
          process.send(reply, Ok(option.Some(updated)))
          actor.continue(
            State(
              ..state,
              next_post: state.next_post + 1,
              threads: dict.insert(state.threads, updated.id, updated),
            ),
          )
        }
      }
    Get(id:, reply:) -> {
      process.send(reply, Ok(dict.get(state.threads, id) |> option.from_result))
      actor.continue(state)
    }
    Recent(offset:, limit:, reply:) -> {
      let threads =
        dict.values(state.threads)
        |> list.sort(fn(a, b) {
          timestamp.compare(b.last_activity, a.last_activity)
          |> order.lazy_break_tie(fn() { int.compare(b.id, a.id) })
        })
        |> list.drop(offset)
        |> list.take(limit)
      process.send(reply, Ok(threads))
      actor.continue(state)
    }
  }
}
