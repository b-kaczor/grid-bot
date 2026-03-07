# Self-Scheduling Sidekiq Worker

## When to Use

- A worker needs to run repeatedly at a fixed interval (e.g., every 15 seconds)
- The interval is too short for `sidekiq-cron` (minimum cron resolution is 1 minute)
- You want the next run to be enqueued only after the current run completes, avoiding pile-up

## Steps

1. **Enqueue the next run at the end of `perform`**:
   ```ruby
   def perform
     do_work
   ensure
     self.class.perform_in(INTERVAL)
   end
   ```
   Using `ensure` means the next job is enqueued even if the current run raises. This prevents the chain from dying on a transient error.

2. **Bootstrap via initializer or after-deploy hook** — self-scheduling only continues the chain; something must start it. Add an initializer:
   ```ruby
   # config/initializers/sidekiq_workers.rb
   GridReconciliationWorker.perform_async unless Sidekiq::Queue.new('default').any? { ... }
   ```
   Or enqueue once from a deploy task.

3. **Guard against duplicate chains** — if the app restarts, a new chain starts while old jobs may still be in the queue. Use a Redis lock (e.g., `SET NX EX`) at the start of `perform` and skip if the lock is held:
   ```ruby
   def perform
     acquired = redis.set("lock:reconciliation", 1, nx: true, ex: INTERVAL + 5)
     return unless acquired
     do_work
   ensure
     self.class.perform_in(INTERVAL)
   end
   ```

4. **Use `perform_in` not `perform_async`** — the delay ensures other workers have time to process between cycles.

## Key Files

- `app/workers/grid_reconciliation_worker.rb` — reference implementation (15-second interval)

## Example

- See: `phase2-execution-loop/` — GridReconciliationWorker uses self-scheduling because 15s is below cron resolution
