//// An in-memory store of notes, held by one process.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result

pub type Note {
  Note(id: Int, title: String, body: String)
}

pub opaque type Notes {
  Notes(subject: Subject(Message))
}

type State {
  State(next_id: Int, notes: Dict(Int, Note))
}

type Message {
  All(reply: Subject(List(Note)))
  Get(id: Int, reply: Subject(Result(Note, Nil)))
  Create(title: String, body: String, reply: Subject(Note))
  Delete(id: Int, reply: Subject(Result(Nil, Nil)))
}

pub fn start() -> Result(Notes, actor.StartError) {
  actor.new(State(next_id: 1, notes: dict.new()))
  |> actor.on_message(on_message)
  |> actor.start
  |> result.map(fn(started) { Notes(started.data) })
}

/// Every note, oldest first.
pub fn all(notes: Notes) -> List(Note) {
  process.call(notes.subject, 1000, All)
}

pub fn get(notes: Notes, id: Int) -> Result(Note, Nil) {
  process.call(notes.subject, 1000, Get(id, _))
}

pub fn create(notes: Notes, title: String, body: String) -> Note {
  process.call(notes.subject, 1000, Create(title, body, _))
}

pub fn delete(notes: Notes, id: Int) -> Result(Nil, Nil) {
  process.call(notes.subject, 1000, Delete(id, _))
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    All(reply:) -> {
      dict.values(state.notes)
      |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
      |> process.send(reply, _)
      actor.continue(state)
    }
    Get(id:, reply:) -> {
      process.send(reply, dict.get(state.notes, id))
      actor.continue(state)
    }
    Create(title:, body:, reply:) -> {
      let note = Note(id: state.next_id, title:, body:)
      process.send(reply, note)
      actor.continue(State(
        next_id: state.next_id + 1,
        notes: dict.insert(state.notes, note.id, note),
      ))
    }
    Delete(id:, reply:) ->
      case dict.has_key(state.notes, id) {
        True -> {
          process.send(reply, Ok(Nil))
          actor.continue(State(..state, notes: dict.delete(state.notes, id)))
        }
        False -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
      }
  }
}
