import { toList } from "./gleam.mjs";

export function new_log() {
  return [];
}

export function push(log, entry) {
  log.push(entry);
}

export function entries(log) {
  return toList(log);
}

export function delay(ms) {
  return new Promise((resolve) => setTimeout(() => resolve(undefined), ms));
}
