import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  trailingSlash: "ignore",
  redirects: {
    "/docs": "/docs/getting-started/installation",
  },
  vite: {
    plugins: [tailwindcss()],
  },
});
