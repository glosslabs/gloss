import { getEntry, type CollectionEntry } from "astro:content";

export const siteName = "Gloss Docs";

export type Section = { title: string; slug: string; articles: string[] };

/// The sidebar, in order. Articles are slugs under `src/content/docs/<section slug>/`.
/// Only articles listed here are built.
export const sections: Section[] = [
  {
    title: "Prologue",
    slug: "prologue",
    articles: ["release-notes", "upgrade-guide", "contribution-guide"],
  },
  {
    title: "Getting Started",
    slug: "getting-started",
    articles: [
      "installation",
      "configuration",
      "directory-structure",
      "frontend",
      "starter-template",
      "deployment",
    ],
  },
  {
    title: "Architecture Concepts",
    slug: "architecture",
    articles: [
      "request-lifecycle",
      "application-state",
      "supervision",
      "contracts-and-adapters",
      "bounded-contexts",
    ],
  },
  {
    title: "The Basics",
    slug: "basics",
    articles: [
      "routing",
      "middleware",
      "csrf-protection",
      "handlers",
      "requests",
      "responses",
      "views",
      "glx",
      "styling",
      "session",
      "validation",
      "error-handling",
      "logging",
    ],
  },
  {
    title: "Digging Deeper",
    slug: "digging-deeper",
    articles: [
      "cli",
      "websockets",
      "server-sent-events",
      "cache",
      "events",
      "file-storage",
      "file-uploads",
      "static-files",
      "http-client",
      "localization",
      "mail",
      "notifications",
      "queues",
      "rate-limiting",
      "task-scheduling",
    ],
  },
  {
    title: "Security",
    slug: "security",
    articles: [
      "authentication",
      "authorization",
      "email-verification",
      "password-reset",
      "hashing",
      "api-tokens",
      "oauth",
      "cors",
      "security-headers",
    ],
  },
  {
    title: "Database",
    slug: "database",
    articles: [
      "getting-started",
      "queries",
      "query-builder",
      "pagination",
      "migrations",
      "seeding",
      "key-value-store",
    ],
  },
  {
    title: "Sync",
    slug: "sync",
    articles: [
      "getting-started",
      "schema",
      "client",
      "live-queries",
      "mutations",
      "conflict-resolution",
      "permissions",
      "offline-storage",
    ],
  },
  {
    title: "Observability",
    slug: "observability",
    articles: [
      "tracing",
      "opentelemetry",
      "error-reporting",
      "health-checks",
      "devtools",
    ],
  },
  {
    title: "Testing",
    slug: "testing",
    articles: ["getting-started", "http-tests", "websocket-tests", "fakes"],
  },
  {
    title: "Packages",
    slug: "packages",
    articles: ["sentry", "billing", "writing-packages"],
  },
];

export type Nav = { title: string; articles: CollectionEntry<"docs">[] }[];

export async function loadNav(): Promise<Nav> {
  return Promise.all(
    sections.map(async (section) => ({
      title: section.title,
      articles: await Promise.all(
        section.articles.map(async (slug) => {
          const id = `${section.slug}/${slug}`;
          const entry = await getEntry("docs", id);
          if (!entry) throw new Error(`No article at src/content/docs/${id}.md`);
          return entry;
        }),
      ),
    })),
  );
}

export function route(entry: CollectionEntry<"docs">): string {
  return `/docs/${entry.id}`;
}
