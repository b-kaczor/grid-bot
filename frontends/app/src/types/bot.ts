import type { Trade } from './trade.ts';

export interface Bot {
  id: number;
  pair: string;
  base_coin: string;
  quote_coin: string;
  status: 'pending' | 'initializing' | 'running' | 'paused' | 'stopping' | 'stopped' | 'error';
  lower_price: string;
  upper_price: string;
  grid_count: number;
  spacing_type: 'arithmetic' | 'geometric';
  investment_amount: string;
  tick_size?: string;
  base_precision?: number;
  quote_precision?: number;
  current_price?: string;
  realized_profit?: string;
  unrealized_pnl?: string;
  trade_count?: number;
  active_levels?: number;
  uptime_seconds?: number;
  stop_loss_price?: string | null;
  take_profit_price?: string | null;
  trailing_up_enabled: boolean;
  stop_reason?: string | null;
  created_at: string;
}

export interface BotDetail extends Bot {
  recent_trades: Trade[];
}

export interface GridLevel {
  level_index: number;
  price: string;
  expected_side: 'buy' | 'sell';
  status: 'pending' | 'active' | 'filled' | 'skipped';
  cycle_count: number;
}

export interface GridData {
  current_price: string;
  levels: GridLevel[];
}

export interface CreateBotParams {
  pair: string;
  base_coin: string;
  quote_coin: string;
  lower_price: string;
  upper_price: string;
  grid_count: number;
  spacing_type: 'arithmetic' | 'geometric';
  investment_amount: string;
  stop_loss_price?: string;
  take_profit_price?: string;
  trailing_up_enabled?: boolean;
}

// Re-export Trade for convenience
export type { Trade };
