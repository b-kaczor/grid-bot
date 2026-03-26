import type { Pagination } from './trade.ts';

export interface FilledOrder {
  id: number;
  level_index: number;
  side: 'buy' | 'sell';
  price: string;
  quantity: string;
  avg_fill_price: string;
  filled_quantity: string;
  fee: string;
  fee_coin: string;
  filled_at: string;
}

export interface PaginatedOrders {
  orders: FilledOrder[];
  pagination: Pagination;
}
