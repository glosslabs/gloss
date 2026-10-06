import app/handlers/health
import app/handlers/notes
import app/handlers/users
import app/middleware/auth
import app/state.{type State}
import gloss/http/router.{type Router}

pub fn routes() -> Router(State) {
  let public =
    router.new()
    |> router.get("/health", health.show)

  let account =
    router.group("/auth")
    |> router.with(auth.authenticate)
    |> router.get("/me", users.me)

  let notes =
    router.group("/notes")
    |> router.with(auth.authenticate)
    |> router.get("/", notes.index)
    |> router.post("/", notes.create)
    |> router.get("/:id", notes.show)
    |> router.delete("/:id", notes.delete)

  router.combine([public, account, notes])
}
