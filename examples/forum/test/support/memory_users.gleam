//// The user store, answered from memory, for tests.

import domain/accounts/user.{type User, User}
import domain/accounts/user_store.{
  type Message, type UserStore, DuplicateEmail, FindByEmail, Get, GetMany,
  Insert, Inserted, Save,
}
import gleam/dict.{type Dict}
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
          store.reply(Ok(DuplicateEmail), reply)
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
          store.reply(Ok(Inserted(created)), reply)
          State(
            next_id: state.next_id + 1,
            users: dict.insert(state.users, created.id, created),
          )
        }
      }
    Get(id:, reply:) -> {
      store.reply(Ok(dict.get(state.users, id) |> option.from_result), reply)
      state
    }
    GetMany(ids:, reply:) -> {
      store.reply(Ok(list.filter_map(ids, dict.get(state.users, _))), reply)
      state
    }
    FindByEmail(email:, reply:) -> {
      store.reply(Ok(find(state, email)), reply)
      state
    }
    Save(user:, reply:) -> {
      store.reply(Ok(Nil), reply)
      State(..state, users: dict.insert(state.users, user.id, user))
    }
  }
}

fn find(state: State, email: String) -> Option(User) {
  dict.values(state.users)
  |> list.find(fn(user) { user.email == email })
  |> option.from_result
}
