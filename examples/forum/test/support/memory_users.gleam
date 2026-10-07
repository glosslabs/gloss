//// The user store, answered from memory, for tests.

import domain/accounts/user.{type User, User}
import domain/accounts/user_store.{
  type Message, type UserStore, DuplicateEmail, FindByEmail, Get, GetMany,
  Insert, Inserted, Save,
}
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gloss/store

type State {
  State(next_id: Int, users: Dict(Int, User))
}

pub fn start() -> UserStore {
  let assert Ok(users) =
    store.serial(State(next_id: 1, users: dict.new()), answer) |> store.start
  users
}

fn answer(state: State, message: Message) -> State {
  case message {
    Insert(user: new, reply:) ->
      case find(state, new.email) {
        Some(_) -> {
          process.send(reply, Ok(DuplicateEmail))
          state
        }
        None -> {
          let created =
            User(
              id: state.next_id,
              email: new.email,
              display_name: new.display_name,
              bio: "",
              avatar: None,
              password_hash: new.password_hash,
              joined_at: new.joined_at,
            )
          process.send(reply, Ok(Inserted(created)))
          State(
            next_id: state.next_id + 1,
            users: dict.insert(state.users, created.id, created),
          )
        }
      }
    Get(id:, reply:) -> {
      process.send(reply, Ok(dict.get(state.users, id) |> option.from_result))
      state
    }
    GetMany(ids:, reply:) -> {
      process.send(reply, Ok(list.filter_map(ids, dict.get(state.users, _))))
      state
    }
    FindByEmail(email:, reply:) -> {
      process.send(reply, Ok(find(state, email)))
      state
    }
    Save(user:, reply:) -> {
      process.send(reply, Ok(Nil))
      State(..state, users: dict.insert(state.users, user.id, user))
    }
  }
}

fn find(state: State, email: String) -> Option(User) {
  dict.values(state.users)
  |> list.find(fn(user) { user.email == email })
  |> option.from_result
}
