import gloss/http/router.{type Router}
import json_api/app.{type App}
import json_api/web/auth
import json_api/web/health
import json_api/web/notes
import json_api/web/users

pub fn routes() -> Router(App) {
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
