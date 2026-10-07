<p align="center" style="padding: 48px 0;">
    <a href="https://glosslabs.dev" target="_blank">
        <img
            src="asset/hero.svg"
            width="240">
    </a>
</p>


## About Gloss

> **Note:** Gloss is under active development and has not yet reached an initial release.

Gloss is a progressive framework for building modern web applications with [Gleam](https://gleam.run/).   

| Package | |
|---|---|
| [`gloss`](packages/gloss) | HTTP server and router, database layer (`gloss/sql`), tracer, logger, scheduler and signals |
| [`gloss_pg`](packages/gloss_pg) | Postgres driver for `gloss/sql` (`gloss/pg`) |
| [`gloss_test`](packages/gloss_test) | Test helpers: requests, responses, a cookie-keeping browser, HTML readers, a WebSocket client, a test clock and ids (`gloss/testing/*`) |
| [`gloss_sentry`](packages/gloss_sentry) | Report failures to Sentry |
| [`gloss_otel`](packages/gloss_otel) | Export spans and logs to OpenTelemetry over OTLP/HTTP |

[`template`](template) is the starting point for a new application, and [`examples`](examples) shows the packages in use.


## License
Gloss is open-sourced software licensed under the [MIT license](LICENSE.md).
