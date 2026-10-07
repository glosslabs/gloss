import domain/forum
import domain/forum/thread
import gleam/int
import gleam/list
import gleeunit/should
import support/memory_threads

pub fn open_and_reply_test() {
  let forum = forum.new(memory_threads.start())
  let assert Ok(opened) = forum.open_thread(forum, 1, " Hello ", "First")
  opened.title |> should.equal("Hello")
  forum.open_thread(forum, 1, "", "x")
  |> should.equal(Error(thread.TitleMissing))

  let assert Ok(replied) = forum.reply(forum, opened.id, 2, "Second")
  thread.replies(replied) |> should.equal(1)
  thread.author_id(replied) |> should.equal(1)
  forum.reply(forum, opened.id, 2, "  ")
  |> should.equal(Error(forum.InvalidReply(thread.BodyMissing)))
  forum.reply(forum, 99, 2, "x") |> should.equal(Error(forum.ThreadNotFound))
}

pub fn pages_are_most_recently_active_first_test() {
  let forum = forum.new(memory_threads.start())
  list.each([1, 2, 3], fn(n) {
    let assert Ok(_) = forum.open_thread(forum, 1, "T" <> int.to_string(n), "x")
    Nil
  })
  // Replying moves a thread to the top.
  let assert Ok(_) = forum.reply(forum, 1, 1, "bump")
  let page = forum.page(forum, 1, 2)
  list.map(page.threads, fn(t) { t.title }) |> should.equal(["T1", "T3"])
  page.has_next |> should.be_true
  let page = forum.page(forum, 2, 2)
  list.map(page.threads, fn(t) { t.title }) |> should.equal(["T2"])
  page.has_next |> should.be_false
}
