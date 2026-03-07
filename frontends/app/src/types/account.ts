export interface ExchangeAccount {
  id: number;
  name: string;
  exchange: string;
  environment: string;
  api_key_hint: string;
  created_at: string;
  updated_at: string;
}

export interface TestConnectionResult {
  success: boolean;
  balance?: string;
  error?: string;
}

export const ENVIRONMENTS = [
  { value: 'testnet', label: 'Testnet' },
  { value: 'demo', label: 'Demo' },
  { value: 'mainnet', label: 'Mainnet' },
] as const;
