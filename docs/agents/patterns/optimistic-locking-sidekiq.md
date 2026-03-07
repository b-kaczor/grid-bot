# Optimistic Locking in Sidekiq Workers

## When to Use

- Multiple concurrent Sidekiq workers can race on the same DB record
- You need exactly-once semantics for a side-effectful operation (e.g., placing a counter-order)
- The operation is idempotent on retry but must not run twice on the same trigger

## Steps

1. **Add `lock_version` to the model** (standard ActiveRecord optimistic locking):
   ```ruby
   # migration
   add_column :grid_levels, :lock_version, :integer, default: 0, null: false
   ```
   ActiveRecord increments `lock_version` on every `save!` and raises `ActiveRecord::StaleObjectError` if another process updated the row since you loaded it.

2. **Load the record inside the transaction** — load it as late as possible, right before the write, to minimize the race window.

3. **Rescue `StaleObjectError` and retry** — Sidekiq retry handles this automatically if you let the error propagate. Alternatively, rescue it explicitly and re-raise to let Sidekiq schedule a retry.

4. **Add an idempotency check before the lock** — check a cheap condition first (e.g., `order.status == 'filled'`) to short-circuit duplicate messages without acquiring any lock:
   ```ruby
   def perform(order_data)
     order = Order.find_by!(exchange_order_id: order_data['orderId'])
     return if order.filled?   # idempotency guard

     ActiveRecord::Base.transaction do
       level = GridLevel.lock.find(order.grid_level_id)  # SELECT FOR UPDATE or optimistic
       # ... place counter-order, update level
       level.save!  # raises StaleObjectError if race
     end
   end
   ```

5. **Do not rescue `StaleObjectError` silently** — the loser must retry, not skip. A skipped retry means a missing counter-order.

## Key Files

- `app/workers/order_fill_worker.rb` — reference implementation
- `app/models/grid_level.rb` — model with `lock_version`

## Example

- See: `phase2-execution-loop/ARCHITECTURE.md` §3 for the OrderFillWorker concurrency design
