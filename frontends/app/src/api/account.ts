import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import apiClient from './client.ts';
import type { ExchangeAccount, TestConnectionResult } from '../types/account.ts';

export const ACCOUNT_QUERY_KEY = ['exchange_account'];

export const useExchangeAccount = () =>
  useQuery<ExchangeAccount | null>({
    queryKey: ACCOUNT_QUERY_KEY,
    queryFn: () =>
      apiClient.get('/exchange_account/current').then((r) => r.data.account),
    retry: false,
  });

export const useCreateAccount = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: {
      name: string;
      exchange: string;
      environment: string;
      api_key: string;
      api_secret: string;
    }) => apiClient.post('/exchange_account', { exchange_account: data }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ACCOUNT_QUERY_KEY }),
  });
};

export const useUpdateAccount = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (
      data: Partial<{
        name: string;
        environment: string;
        api_key: string;
        api_secret: string;
      }>,
    ) =>
      apiClient.patch('/exchange_account/current', { exchange_account: data }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ACCOUNT_QUERY_KEY }),
  });
};

export const useTestConnection = () =>
  useMutation<TestConnectionResult, Error, { environment: string; api_key: string; api_secret: string }>({
    mutationFn: (data) =>
      apiClient.post('/exchange_account/test', data).then((r) => r.data),
  });
