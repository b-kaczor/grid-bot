import {
  Slider,
  Typography,
  Box,
  Card,
  CardContent,
  Skeleton,
  Alert,
  Divider,
} from '@mui/material';
import { useExchangeBalance } from '../../api/exchange.ts';
import type { TradingPair } from '../../types/exchange.ts';
import type { GridParameters } from './gridParameters.ts';

interface StepInvestmentProps {
  pair: TradingPair;
  params: GridParameters;
  investmentPct: number;
  onInvestmentPctChange: (pct: number) => void;
}

export const StepInvestment = ({
  pair,
  params,
  investmentPct,
  onInvestmentPctChange,
}: StepInvestmentProps) => {
  const { data: balances, isLoading, isError } = useExchangeBalance();

  if (isLoading) {
    return <Skeleton variant="rounded" height={200} />;
  }

  if (isError) {
    return <Alert severity="error">Failed to load balance. Please try again.</Alert>;
  }

  const usdtBalance = balances?.find((b) => b.coin === 'USDT');
  const available = parseFloat(usdtBalance?.available ?? '0');
  const investmentAmount = available * (investmentPct / 100);
  const lastPrice = parseFloat(pair.last_price);
  const qtyPerLevel = params.gridCount > 0 ? investmentAmount / params.gridCount / lastPrice : 0;
  const feeImpact = params.gridCount * 2 * qtyPerLevel * lastPrice * 0.001;

  return (
    <Box sx={{ mt: 2 }}>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
        Available USDT: {available.toFixed(2)}
      </Typography>

      <Box sx={{ mt: 2 }}>
        <Typography gutterBottom>
          Investment: {investmentPct}% ({investmentAmount.toFixed(2)} USDT)
        </Typography>
        <Slider
          value={investmentPct}
          onChange={(_e, val) => onInvestmentPctChange(val as number)}
          min={10}
          max={100}
          step={1}
          valueLabelDisplay="auto"
          valueLabelFormat={(v) => `${v}%`}
        />
      </Box>

      <Card variant="outlined" sx={{ mt: 3 }}>
        <CardContent>
          <Typography variant="subtitle2" gutterBottom>
            Order Summary
          </Typography>
          <Divider sx={{ mb: 1 }} />

          <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
            <Typography variant="body2" color="text.secondary">Pair</Typography>
            <Typography variant="body2">{pair.symbol}</Typography>
          </Box>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
            <Typography variant="body2" color="text.secondary">Range</Typography>
            <Typography variant="body2">{params.lowerPrice} — {params.upperPrice}</Typography>
          </Box>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
            <Typography variant="body2" color="text.secondary">Grid Count</Typography>
            <Typography variant="body2">{params.gridCount}</Typography>
          </Box>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
            <Typography variant="body2" color="text.secondary">Spacing</Typography>
            <Typography variant="body2" sx={{ textTransform: 'capitalize' }}>{params.spacingType}</Typography>
          </Box>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
            <Typography variant="body2" color="text.secondary">Total Investment</Typography>
            <Typography variant="body2">{investmentAmount.toFixed(2)} USDT</Typography>
          </Box>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
            <Typography variant="body2" color="text.secondary">Qty per Level</Typography>
            <Typography variant="body2">{qtyPerLevel > 0 ? qtyPerLevel.toFixed(6) : '—'} {pair.base_coin}</Typography>
          </Box>
          <Box sx={{ display: 'flex', justifyContent: 'space-between' }}>
            <Typography variant="body2" color="text.secondary">Est. Round-trip Fees</Typography>
            <Typography variant="body2">{feeImpact > 0 ? `${feeImpact.toFixed(2)} USDT` : '—'}</Typography>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
};
