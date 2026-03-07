import {
  Slider,
  Typography,
  Box,
  Card,
  CardContent,
  Skeleton,
  Alert,
  Divider,
  TextField,
  InputAdornment,
} from '@mui/material';
import { useExchangeBalance } from '../../api/exchange.ts';
import type { TradingPair } from '../../types/exchange.ts';
import type { GridParameters } from './gridParameters.ts';

interface StepInvestmentProps {
  pair: TradingPair;
  params: GridParameters;
  investmentAmount: string;
  onInvestmentAmountChange: (amount: string) => void;
}

export const StepInvestment = ({
  pair,
  params,
  investmentAmount,
  onInvestmentAmountChange,
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
  const amount = parseFloat(investmentAmount) || 0;
  const clamped = Math.min(Math.max(amount, 0), available);
  const sliderPct = available > 0 ? (clamped / available) * 100 : 0;
  const lastPrice = parseFloat(pair.last_price);
  const qtyPerLevel = params.gridCount > 0 ? clamped / params.gridCount / lastPrice : 0;
  const feeImpact = params.gridCount * 2 * qtyPerLevel * lastPrice * 0.001;

  const handleSliderChange = (_e: Event, val: number | number[]) => {
    const pct = val as number;
    const newAmount = (available * pct) / 100;
    onInvestmentAmountChange(newAmount.toFixed(2));
  };

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const raw = e.target.value;
    if (raw === '' || /^\d*\.?\d{0,2}$/.test(raw)) {
      onInvestmentAmountChange(raw);
    }
  };

  const handleInputBlur = () => {
    if (investmentAmount === '') {
      onInvestmentAmountChange('0');
      return;
    }
    const parsed = parseFloat(investmentAmount);
    if (isNaN(parsed) || parsed < 0) {
      onInvestmentAmountChange('0');
    } else if (parsed > available) {
      onInvestmentAmountChange(available.toFixed(2));
    }
  };

  return (
    <Box sx={{ mt: 2 }}>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
        Available USDT: {available.toFixed(2)}
      </Typography>

      <TextField
        label="Investment Amount"
        value={investmentAmount}
        onChange={handleInputChange}
        onBlur={handleInputBlur}
        size="small"
        sx={{ mt: 1, mb: 1 }}
        slotProps={{
          input: {
            endAdornment: <InputAdornment position="end">USDT</InputAdornment>,
          },
        }}
        data-testid="investment-amount-input"
      />

      <Box sx={{ mt: 1 }}>
        <Typography variant="body2" color="text.secondary" gutterBottom>
          {Math.round(sliderPct)}% of available balance
        </Typography>
        <Slider
          value={sliderPct}
          onChange={handleSliderChange}
          min={0}
          max={100}
          step={1}
          valueLabelDisplay="auto"
          valueLabelFormat={(v) => `${Math.round(v)}%`}
          data-testid="investment-slider"
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
            <Typography variant="body2">{clamped.toFixed(2)} USDT</Typography>
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
