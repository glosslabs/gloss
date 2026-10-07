//// The user repository, answered from memory, for tests.

import domain/accounts/user.{User}
import domain/accounts/user_repository.{
  type Message, type UserRepository, DuplicateEmail, FindByEmail, Get, GetMany,
  Insert, Inserted, Save,
}
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor

type State {
  State(next_id: Int, users: Dict(Int, user.User))
}

pub fn start() -> UserRepository {
  let assert Ok(started) =
    actor.new(State(next_id: 1, users: dict.new()))
    |> actor.on_message(answer)
    |> actor.start
  started.data
}

fn answer(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Insert(user: new, reply:) ->
      case find(state, new.email) {
        option.Some(_) -> {
          process.send(reply, Ok(DuplicateEmail))
          actor.continue(state)
        }
        option.None -> {
          let created =
            User(
              id: state.next_id,
              email: new.email,
              display_name: new.display_name,
              bio: "",
              avatar: option.None,
              password_hash: new.password_hash,
              joined_at: new.joined_at,
            )
          process.send(reply, Ok(Inserted(created)))
          actor.continue(State(
            next_id: state.next_id + 1,
            users: dict.insert(state.users, created.id, created),
          ))
        }
      }
    Get(id:, reply:) -> {
      process.send(reply, Ok(dict.get(state.users, id) |> option.from_result))
      actor.continue(state)
    }
    GetMany(ids:, reply:) -> {
      process.send(reply, Ok(list.filter_map(ids, dict.get(state.users, _))))
      actor.continue(state)
    }
    FindByEmail(email:, reply:) -> {
      process.send(reply, Ok(find(state, email)))
      actor.continue(state)
    }
    Save(user:, reply:) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(..state, users: dict.insert(state.users, user.id, user)),
      )
    }
  }
}

fn find(state: State, email: String) -> option.Option(user.User) {
  dict.values(state.users)
  |> list.find(fn(user) { user.email == email })
  |> option.from_result
}
