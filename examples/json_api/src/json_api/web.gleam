//// The HTTP server: the routes, served with the application's logger and
//// tracer.

import gloss/http/server.{type Builder, type Server, type StartError}
import json_api/app.{type App}
import json_api/config.{type Config}
import json_api/web/routes

pub fn builder(config: Config, ctx: App) -> Builder(App) {
  server.new(routes.routes(), ctx)
  |> server.bind("0.0.0.0")
  |> server.port(config.port)
  |> server.tracer(ctx.tracer)
  |> server.logger(ctx.log)
}

pub fn start(config: Config, ctx: App) -> Result(Server, StartError) {
  builder(config, ctx) |> server.start
}
