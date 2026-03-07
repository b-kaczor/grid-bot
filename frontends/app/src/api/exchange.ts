import { useQuery } from '@tanstack/react-query';
import apiClient from './client.ts';
import type { TradingPair, CoinBalance } from '../types/exchange.ts';

export const useExchangePairs = (quote = 'USDT') =>
  useQuery<TradingPair[]>({
    queryKey: ['exchange', 'pairs', quote],
    queryFn: () =>
      apiClient.get('/exchange/pairs', { params: { quote } }).then((r) => r.data.pairs),
    staleTime: 5 * 60 * 1000,
  });

export const useExchangeBalance = () =>
  useQuery<CoinBalance[]>({
    queryKey: ['exchange', 'balance'],
    queryFn: () => apiClient.get('/exchange/balance').then((r) => r.data.balance.coins),
  });
