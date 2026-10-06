import gleeunit/should
import gloss/internal/http_reply_negotiate.{choose}

const offered = ["application/json", "text/html", "text/plain"]

pub fn no_header_takes_the_first_offer_test() {
  choose(Error(Nil), offered) |> should.equal(Ok("application/json"))
}

pub fn wildcard_takes_the_first_offer_test() {
  choose(Ok("*/*"), offered) |> should.equal(Ok("application/json"))
}

pub fn exact_match_test() {
  choose(Ok("text/html"), offered) |> should.equal(Ok("text/html"))
}

pub fn browser_accept_test() {
  choose(
    Ok("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
    offered,
  )
  |> should.equal(Ok("text/html"))
}

pub fn quality_wins_over_offer_order_test() {
  choose(Ok("application/json;q=0.5, text/plain"), offered)
  |> should.equal(Ok("text/plain"))
}

pub fn type_wildcard_test() {
  choose(Ok("text/*"), offered) |> should.equal(Ok("text/html"))
}

pub fn most_specific_range_decides_test() {
  // text/html is refused outright even though text/* is acceptable.
  choose(Ok("text/*, text/html;q=0"), offered)
  |> should.equal(Ok("text/plain"))
}

pub fn nothing_acceptable_test() {
  choose(Ok("image/png"), offered) |> should.equal(Error(Nil))
}

pub fn case_and_spacing_are_ignored_test() {
  choose(Ok(" Text/HTML ; Q=1 "), offered) |> should.equal(Ok("text/html"))
}
