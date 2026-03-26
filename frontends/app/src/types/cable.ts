import type { GridLevel } from './bot.ts';
import type { Trade } from './trade.ts';

export interface FillEvent {
  type: 'fill';
  grid_level: GridLevel;
  counter_level: GridLevel | null;
  trade: Trade | null;
  realized_profit: string;
  trade_count: number;
}

export interface PriceUpdateEvent {
  type: 'price_update';
  current_price: string;
  unrealized_pnl: string;
  total_value_quote: string;
}

export interface StatusEvent {
  type: 'status';
  status: string;
  stop_reason: string | null;
}

export type BotCableEvent = FillEvent | PriceUpdateEvent | StatusEvent;
