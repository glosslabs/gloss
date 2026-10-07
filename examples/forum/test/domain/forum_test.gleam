import domain/forum
import domain/forum/thread
import gleam/int
import gleam/list
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import gloss/testing/clock as test_clock
import support/memory_threads

fn start() -> #(forum.Forum, test_clock.TestClock) {
  let time = test_clock.new(timestamp.from_unix_seconds(1_700_000_000))
  #(forum.new(memory_threads.start(), test_clock.clock(time)), time)
}

pub fn open_and_reply_test() {
  let #(forum, time) = start()
  let assert Ok(opened) = forum.open_thread(forum, 1, " Hello ", "First")
  opened.title |> should.equal("Hello")
  opened.last_activity |> should.equal(test_clock.now(time))
  forum.open_thread(forum, 1, "", "x")
  |> should.equal(Error(thread.TitleMissing))

  test_clock.advance(time, duration.minutes(5))
  let assert Ok(replied) = forum.reply(forum, opened.id, 2, "Second")
  thread.replies(replied) |> should.equal(1)
  // The reply is stamped five minutes later, and so is the thread.
  let assert [_, reply] = replied.posts
  reply.at |> should.equal(timestamp.from_unix_seconds(1_700_000_300))
  replied.last_activity |> should.equal(reply.at)
  thread.author_id(replied) |> should.equal(1)
  forum.reply(forum, opened.id, 2, "  ")
  |> should.equal(Error(forum.InvalidReply(thread.BodyMissing)))
  forum.reply(forum, 99, 2, "x") |> should.equal(Error(forum.ThreadNotFound))
}

pub fn pages_are_most_recently_active_first_test() {
  let #(forum, time) = start()
  list.each([1, 2, 3], fn(n) {
    test_clock.advance(time, duration.minutes(1))
    let assert Ok(_) = forum.open_thread(forum, 1, "T" <> int.to_string(n), "x")
    Nil
  })
  // Replying moves a thread to the top.
  test_clock.advance(time, duration.minutes(1))
  let assert Ok(_) = forum.reply(forum, 1, 1, "bump")
  let page = forum.page(forum, 1, 2)
  list.map(page.threads, fn(t) { t.title }) |> should.equal(["T1", "T3"])
  page.has_next |> should.be_true
  let page = forum.page(forum, 2, 2)
  list.map(page.threads, fn(t) { t.title }) |> should.equal(["T2"])
  page.has_next |> should.be_false
}
