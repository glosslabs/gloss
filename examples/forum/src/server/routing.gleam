//// The route table, and nothing else.

import gloss/http/router.{type Router}
import gloss/http/static
import server/handlers/accounts
import server/handlers/profile
import server/handlers/threads
import server/handlers/users
import server/middleware/current_user
import server/state.{type State}

pub fn routes(
  assets_dir assets_dir: String,
  avatars_dir avatars_dir: String,
) -> Router(State) {
  let pages =
    router.new()
    |> router.with(current_user.load)
    |> router.get("/", threads.index)
    |> router.get("/threads/new", threads.new)
    |> router.post("/threads", threads.create)
    |> router.get("/threads/:id", threads.show)
    |> router.post("/threads/:id/replies", threads.reply)
    |> router.get("/threads/:id/live", threads.live)
    |> router.get("/users/:id", users.show)

  let account =
    router.new()
    |> router.with(current_user.load)
    |> router.get("/register", accounts.register_form)
    |> router.post("/register", accounts.register)
    |> router.get("/login", accounts.login_form)
    |> router.post("/login", accounts.login)
    |> router.post("/logout", accounts.logout)
    |> router.get("/profile", profile.edit)
    |> router.post("/profile", profile.update)
    |> router.post("/profile/avatar", profile.upload_avatar)

  let files =
    router.new()
    |> router.get("/assets/*path", static.files(assets_dir))
    |> router.get(
      "/avatars/*path",
      // Avatar names are random, so a file never changes once written.
      static.new(avatars_dir)
        |> static.cache_control("public, max-age=31536000, immutable")
        |> static.handler,
    )

  router.combine([pages, account, files])
}
