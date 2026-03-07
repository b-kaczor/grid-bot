import { Autocomplete, TextField, Typography, Box, Skeleton } from '@mui/material';
import { useExchangePairs } from '../../api/exchange.ts';
import type { TradingPair } from '../../types/exchange.ts';

interface StepSelectPairProps {
  selectedPair: TradingPair | null;
  onSelect: (pair: TradingPair | null) => void;
}

export const StepSelectPair = ({ selectedPair, onSelect }: StepSelectPairProps) => {
  const { data: pairs, isLoading } = useExchangePairs();

  if (isLoading) {
    return <Skeleton variant="rounded" height={56} />;
  }

  return (
    <Box sx={{ mt: 2 }}>
      <Typography variant="body1" sx={{ mb: 2 }}>
        Search and select a trading pair to begin.
      </Typography>
      <Autocomplete
        options={pairs ?? []}
        value={selectedPair}
        onChange={(_event, value) => onSelect(value)}
        getOptionLabel={(option) => option.symbol}
        isOptionEqualToValue={(option, value) => option.symbol === value.symbol}
        renderOption={({ key, ...props }, option) => (
          <Box component="li" key={key} {...props} sx={{ display: 'flex', justifyContent: 'space-between', width: '100%' }}>
            <Typography variant="body1">{option.symbol}</Typography>
            <Typography variant="body2" color="text.secondary">
              {option.last_price}
            </Typography>
          </Box>
        )}
        renderInput={(params) => (
          <TextField
            {...params}
            label="Trading Pair"
            placeholder="Search pairs (e.g. ETHUSDT)"
            autoFocus
          />
        )}
        fullWidth
      />
    </Box>
  );
};
