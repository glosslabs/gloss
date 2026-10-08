import { Ok, Error } from "../gleam.mjs";

// A queue: each task starts once the one before it has settled.
export function new_queue() {
  return { tail: Promise.resolve() };
}

export function enqueue(queue, task) {
  const run = queue.tail.then(() => task());
  // Keep the queue moving whether the task succeeds or fails.
  queue.tail = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}

// Run task, resolving to Ok(value) or Error(reason) when it rejects or
// throws, so a transaction can roll back before passing the failure on.
export function settle(task) {
  try {
    return task().then(
      (value) => new Ok(value),
      (reason) => new Error(reason),
    );
  } catch (reason) {
    return Promise.resolve(new Error(reason));
  }
}

export function reject(reason) {
  return Promise.reject(reason);
}
