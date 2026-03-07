export interface Trade {
  id: number;
  level_index: number;
  buy_price: string;
  sell_price: string;
  quantity: string;
  gross_profit: string;
  total_fees: string;
  net_profit: string;
  completed_at: string;
}

export interface PaginatedTrades {
  trades: Trade[];
  pagination: Pagination;
}

export interface Pagination {
  page: number;
  per_page: number;
  total: number;
  total_pages: number;
}
