# ActionCable React Integration

## When to Use

- A React page needs real-time push updates from the Rails backend without polling
- Updates are scoped to a specific resource (e.g., a single bot) rather than broadcast globally
- The page mixes REST data (React Query) with live push data (ActionCable)

## Steps

1. **Create the Rails channel** (`app/channels/{resource}_channel.rb`):
   - Subscribe using a resource identifier from `params`
   - Stream from a named channel: `stream_from "bot_channel_#{params[:bot_id]}"`
   - Keep channel logic thin — business logic belongs in service objects/workers

2. **Broadcast from workers/services**:
   - After state change, call `ActionCable.server.broadcast("bot_channel_#{bot_id}", payload)`
   - Include a `type` field in the payload so the client can route the update

3. **Create the ActionCable consumer** (`frontends/app/src/cable/consumer.ts`):
   ```ts
   import { createConsumer } from "@rails/actioncable";
   export const consumer = createConsumer("ws://localhost:3000/cable");
   ```

4. **Create a typed hook** (`frontends/app/src/cable/useBotChannel.ts`):
   - Accept the resource ID and a callback
   - Subscribe on mount, unsubscribe on unmount (`useEffect` cleanup)
   - Pass received data through to the callback typed against `CableMessage`

5. **Use in page component**:
   - Call the hook with the resource ID and a handler function
   - Handler merges push data into local React state
   - React Query handles initial load + background refresh; ActionCable handles incremental updates

6. **Show connection status** (`ConnectionBanner` component):
   - Expose consumer status (`connecting` / `connected` / `disconnected`)
   - Render a banner when disconnected so the user knows data may be stale

## Key Files

- `app/channels/bot_channel.rb` — reference implementation
- `frontends/app/src/cable/consumer.ts` — shared consumer singleton
- `frontends/app/src/cable/useBotChannel.ts` — typed subscription hook
- `frontends/app/src/components/ConnectionBanner.tsx` — connection status UI
- `frontends/app/src/types/cable.ts` — `CableMessage` discriminated union type

## Example

See: `docs/agents/grid-engine/phase3-dashboard/` — full Phase 3 implementation reference.
