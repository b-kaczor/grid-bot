import {
  TextField,
  Slider,
  ToggleButtonGroup,
  ToggleButton,
  Typography,
  Box,
  Card,
  CardContent,
  Grid,
  FormControlLabel,
  Switch,
  Alert,
  InputAdornment,
} from '@mui/material';
import type { TradingPair } from '../../types/exchange.ts';
import { validateParameters, deriveGridCount, getProfitTargetWarning } from './gridParameters.ts';
import type { GridParameters } from './gridParameters.ts';

interface StepSetParametersProps {
  pair: TradingPair;
  params: GridParameters;
  onChange: (params: GridParameters) => void;
}

export const StepSetParameters = ({ pair, params, onChange }: StepSetParametersProps) => {
  const errors = validateParameters(params, pair.last_price);

  const lower = parseFloat(params.lowerPrice);
  const upper = parseFloat(params.upperPrice);
  const isGeometric = params.spacingType === 'geometric';

  const stepSize = !isNaN(lower) && !isNaN(upper) && params.gridCount > 1
    ? (upper - lower) / params.gridCount
    : 0;
  const profitPerGrid = !isNaN(lower) && !isNaN(upper) && lower > 0 && upper > lower && params.gridCount > 1
    ? isGeometric
      ? (Math.pow(upper / lower, 1 / params.gridCount) - 1) * 100
      : (stepSize / lower) * 100
    : 0;

  const isProfitActive =
    params.targetProfitPct !== '' && parseFloat(params.targetProfitPct) > 0;

  const profitWarning = getProfitTargetWarning(params);

  const targetPct = parseFloat(params.targetProfitPct);
  const showRoundingDelta =
    isProfitActive && profitPerGrid > 0 && Math.abs(profitPerGrid - targetPct) > 0.01;

  const rederiveGridCount = (newLower: number, newUpper: number, pct: number): number => {
    const derived = deriveGridCount(newLower, newUpper, pct, params.spacingType);
    return Math.min(Math.max(derived, 2), 200);
  };

  const handleProfitPctChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = e.target.value;
    const pct = parseFloat(val);

    if (val !== '' && !isNaN(pct) && pct > 0 && !isNaN(lower) && !isNaN(upper) && lower > 0 && upper > lower) {
      onChange({ ...params, targetProfitPct: val, gridCount: rederiveGridCount(lower, upper, pct) });
    } else {
      onChange({ ...params, targetProfitPct: val });
    }
  };

  const handleGridCountChange = (_e: Event, val: number | number[]) => {
    // Escape hatch: manually changing grid count clears profit target
    onChange({ ...params, targetProfitPct: '', gridCount: val as number });
  };

  const handleLowerPriceChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const newLower = e.target.value;
    const parsedLower = parseFloat(newLower);

    if (isProfitActive) {
      const pct = parseFloat(params.targetProfitPct);
      if (!isNaN(parsedLower) && parsedLower > 0 && !isNaN(upper) && upper > parsedLower && !isNaN(pct) && pct > 0) {
        onChange({ ...params, lowerPrice: newLower, gridCount: rederiveGridCount(parsedLower, upper, pct) });
      } else {
        onChange({ ...params, lowerPrice: newLower });
      }
    } else {
      onChange({ ...params, lowerPrice: newLower });
    }
  };

  const handleUpperPriceChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const newUpper = e.target.value;
    const parsedUpper = parseFloat(newUpper);

    if (isProfitActive) {
      const pct = parseFloat(params.targetProfitPct);
      if (!isNaN(lower) && lower > 0 && !isNaN(parsedUpper) && parsedUpper > lower && !isNaN(pct) && pct > 0) {
        onChange({ ...params, upperPrice: newUpper, gridCount: rederiveGridCount(lower, parsedUpper, pct) });
      } else {
        onChange({ ...params, upperPrice: newUpper });
      }
    } else {
      onChange({ ...params, upperPrice: newUpper });
    }
  };

  return (
    <Box sx={{ mt: 2 }}>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        {pair.symbol} — Last price: {pair.last_price}
      </Typography>

      <Grid container spacing={2}>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            data-testid="input-lower-price"
            label="Lower Price"
            value={params.lowerPrice}
            onChange={handleLowerPriceChange}
            error={!!errors.lowerPrice}
            helperText={errors.lowerPrice}
            type="number"
            fullWidth
            slotProps={{ htmlInput: { step: pair.tick_size, min: 0 } }}
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            data-testid="input-upper-price"
            label="Upper Price"
            value={params.upperPrice}
            onChange={handleUpperPriceChange}
            error={!!errors.upperPrice}
            helperText={errors.upperPrice}
            type="number"
            fullWidth
            slotProps={{ htmlInput: { step: pair.tick_size, min: 0 } }}
          />
        </Grid>
      </Grid>

      <Box sx={{ mt: 3 }}>
        <Typography gutterBottom>Grid Count: {params.gridCount}</Typography>
        <Slider
          data-testid="input-grid-count"
          value={params.gridCount}
          onChange={handleGridCountChange}
          disabled={isProfitActive}
          min={2}
          max={200}
          valueLabelDisplay="auto"
        />
        {isProfitActive && (
          <Typography variant="caption" color="text.secondary">
            Computed from profit target
          </Typography>
        )}
      </Box>

      {isGeometric && (
        <Box sx={{ mt: 3, p: 2, border: '1px solid', borderColor: 'divider', borderRadius: 1 }}>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 1.5 }}>
            Profit target (optional)
          </Typography>
          <TextField
            label="Profit % per level"
            value={params.targetProfitPct}
            onChange={handleProfitPctChange}
            error={!!errors.targetProfitPct}
            helperText={errors.targetProfitPct || ' '}
            type="number"
            size="small"
            sx={{ width: { xs: '100%', sm: 200 } }}
            slotProps={{
              htmlInput: { step: 0.01, min: 0, max: 100 },
              input: { endAdornment: <InputAdornment position="end">%</InputAdornment> },
            }}
          />
          {profitWarning && (
            <Alert severity="warning" sx={{ mt: 1 }}>
              {profitWarning}
            </Alert>
          )}
        </Box>
      )}

      <Box sx={{ mt: 2 }}>
        <Typography gutterBottom>Spacing Type</Typography>
        <ToggleButtonGroup
          value={params.spacingType}
          exclusive
          onChange={(_e, val) => {
            if (!val) return;
            const next = { ...params, spacingType: val as 'arithmetic' | 'geometric' };
            if (val === 'arithmetic' && params.targetProfitPct !== '') {
              next.targetProfitPct = '';
            }
            onChange(next);
          }}
          size="small"
        >
          <ToggleButton value="arithmetic">Arithmetic</ToggleButton>
          <ToggleButton value="geometric">Geometric</ToggleButton>
        </ToggleButtonGroup>
      </Box>

      <Grid container spacing={2} sx={{ mt: 1 }}>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            label="Stop Loss Price (optional)"
            value={params.stopLossPrice}
            onChange={(e) => onChange({ ...params, stopLossPrice: e.target.value })}
            error={!!errors.stopLossPrice}
            helperText={errors.stopLossPrice || 'Leave blank to disable'}
            type="number"
            fullWidth
            slotProps={{ htmlInput: { step: pair.tick_size, min: 0 } }}
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            label="Take Profit Price (optional)"
            value={params.takeProfitPrice}
            onChange={(e) => onChange({ ...params, takeProfitPrice: e.target.value })}
            error={!!errors.takeProfitPrice}
            helperText={errors.takeProfitPrice || 'Leave blank to disable'}
            type="number"
            fullWidth
            slotProps={{ htmlInput: { step: pair.tick_size, min: 0 } }}
          />
        </Grid>
      </Grid>

      <Box sx={{ mt: 2 }}>
        <FormControlLabel
          control={
            <Switch
              checked={params.trailingUpEnabled}
              onChange={(e) => onChange({ ...params, trailingUpEnabled: e.target.checked })}
            />
          }
          label="Trailing Grid"
        />
        {params.trailingUpEnabled && (
          <Alert severity="info" sx={{ mt: 1 }}>
            Trailing keeps the bot running above the grid range by shifting upward. This sells base
            at lower prices and re-buys higher — it is a continuity mechanism, not a profit strategy.
          </Alert>
        )}
      </Box>

      <Card variant="outlined" sx={{ mt: 3 }}>
        <CardContent>
          <Typography variant="subtitle2" gutterBottom>
            Live Preview
          </Typography>
          <Typography variant="body2">
            Grid step size: {stepSize > 0 ? stepSize.toFixed(4) : '—'}
          </Typography>
          <Typography variant="body2">
            Profit per grid: {profitPerGrid > 0 ? `${profitPerGrid.toFixed(2)}%` : '—'}
            {showRoundingDelta && ` (target: ${targetPct.toFixed(2)}%)`}
          </Typography>
        </CardContent>
      </Card>
    </Box>
  );
};
