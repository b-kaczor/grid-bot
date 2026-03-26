import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import apiClient from './client.ts';
import type { Bot, BotDetail, CreateBotParams, GridData } from '../types/bot.ts';
import type { PaginatedTrades } from '../types/trade.ts';
import type { PaginatedOrders } from '../types/order.ts';

interface ChartSnapshot {
  snapshot_at: string;
  total_value_quote: string;
  realized_profit: string;
  unrealized_pnl: string;
  current_price: string;
}

interface ChartResponse {
  snapshots: ChartSnapshot[];
  granularity: string;
}

export const useBots = () =>
  useQuery<Bot[]>({
    queryKey: ['bots'],
    queryFn: () => apiClient.get('/bots').then((r) => r.data.bots),
    refetchInterval: 30_000,
  });

export const useBot = (id: number) =>
  useQuery<BotDetail>({
    queryKey: ['bots', id],
    queryFn: () => apiClient.get(`/bots/${id}`).then((r) => r.data.bot),
    refetchInterval: (query) => {
      const status = query.state.data?.status;
      return status === 'initializing' || status === 'stopping' ? 3_000 : false;
    },
  });

export const useBotGrid = (id: number) =>
  useQuery<GridData>({
    queryKey: ['bots', id, 'grid'],
    queryFn: () => apiClient.get(`/bots/${id}/grid`).then((r) => r.data.grid),
  });

export const useBotTrades = (id: number, page: number) =>
  useQuery<PaginatedTrades>({
    queryKey: ['bots', id, 'trades', page],
    queryFn: () =>
      apiClient.get(`/bots/${id}/trades`, { params: { page } }).then((r) => r.data),
  });

export const useBotOrders = (id: number, page: number) =>
  useQuery<PaginatedOrders>({
    queryKey: ['bots', id, 'orders', page],
    queryFn: () =>
      apiClient.get(`/bots/${id}/orders`, { params: { page } }).then((r) => r.data),
  });

export const useBotChart = (id: number) =>
  useQuery<ChartResponse>({
    queryKey: ['bots', id, 'chart'],
    queryFn: () => apiClient.get(`/bots/${id}/chart`).then((r) => r.data),
  });

export const useCreateBot = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (params: CreateBotParams) => apiClient.post('/bots', { bot: params }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['bots'] }),
  });
};

export const useUpdateBot = (id: number) => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (params: Partial<Bot>) => apiClient.patch(`/bots/${id}`, { bot: params }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['bots'] });
      qc.invalidateQueries({ queryKey: ['bots', id] });
    },
  });
};

export const useDeleteBot = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => apiClient.delete(`/bots/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['bots'] }),
  });
};
