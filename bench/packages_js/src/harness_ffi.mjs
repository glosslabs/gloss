const now = () => Number(process.hrtime.bigint());

function report(name, n, ns) {
  const perOp = ns / n;
  const ops = Math.round(1e9 / perOp).toLocaleString("en-US");
  const time =
    perOp < 1000 ? `${perOp.toFixed(0)} ns` : perOp < 1e6 ? `${(perOp / 1000).toFixed(1)} µs` : `${(perOp / 1e6).toFixed(2)} ms`;
  console.log(name.padEnd(52) + ops.padStart(14) + " ops/s" + time.padStart(12));
}

// Five timed rounds after a warm-up; the median is reported.
export function bench(name, n, f) {
  for (let i = 0; i < n; i++) f();
  const times = [];
  for (let r = 0; r < 5; r++) {
    const start = now();
    for (let i = 0; i < n; i++) f();
    times.push(now() - start);
  }
  times.sort((a, b) => a - b);
  report(name, n, times[2]);
}

export async function bench_async(name, n, f) {
  for (let i = 0; i < n; i++) await f();
  const times = [];
  for (let r = 0; r < 5; r++) {
    const start = now();
    for (let i = 0; i < n; i++) await f();
    times.push(now() - start);
  }
  times.sort((a, b) => a - b);
  report(name, n, times[2]);
}

export function section(title) {
  console.log("\n## " + title);
}
