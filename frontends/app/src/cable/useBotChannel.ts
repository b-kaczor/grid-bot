import { useEffect, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import consumer from './consumer.ts';
import type { BotCableEvent } from '../types/cable.ts';
import type { BotDetail } from '../types/bot.ts';

export const useBotChannel = (botId: number) => {
  const qc = useQueryClient();
  const subRef = useRef<ReturnType<typeof consumer.subscriptions.create> | null>(null);
  const [connectionStatus, setConnectionStatus] = useState<'connected' | 'disconnected'>(
    'disconnected',
  );

  useEffect(() => {
    subRef.current = consumer.subscriptions.create(
      { channel: 'BotChannel', bot_id: botId },
      {
        connected() {
          setConnectionStatus('connected');
        },

        disconnected() {
          setConnectionStatus('disconnected');
        },

        received(event: BotCableEvent) {
          if (event.type === 'fill') {
            qc.setQueryData<BotDetail>(['bots', botId], (old) => {
              if (!old) return old;
              return {
                ...old,
                realized_profit: event.realized_profit,
                trade_count: event.trade_count,
                recent_trades: event.trade
                  ? [event.trade, ...old.recent_trades.slice(0, 9)]
                  : old.recent_trades,
              };
            });
            qc.setQueryData(['bots', botId, 'grid'], (old: unknown) => {
              const grid = old as { current_price: string; levels: Array<{ level_index: number }> } | undefined;
              if (!grid) return old;
              return {
                ...grid,
                levels: grid.levels.map((l) => {
                  if (l.level_index === event.grid_level.level_index) return event.grid_level;
                  if (event.counter_level && l.level_index === event.counter_level.level_index)
                    return event.counter_level;
                  return l;
                }),
              };
            });
            qc.invalidateQueries({ queryKey: ['bots', botId, 'trades'] });
          }

          if (event.type === 'price_update') {
            qc.setQueryData<BotDetail>(['bots', botId], (old) => {
              if (!old) return old;
              return {
                ...old,
                current_price: event.current_price,
                unrealized_pnl: event.unrealized_pnl,
              };
            });
            qc.setQueryData(['bots', botId, 'grid'], (old: unknown) => {
              const grid = old as { current_price: string } | undefined;
              if (!grid) return old;
              return { ...grid, current_price: event.current_price };
            });
          }

          if (event.type === 'status') {
            qc.invalidateQueries({ queryKey: ['bots'] });
            qc.invalidateQueries({ queryKey: ['bots', botId] });
          }
        },
      },
    );

    return () => {
      subRef.current?.unsubscribe();
    };
  }, [botId, qc]);

  return { connectionStatus };
};
