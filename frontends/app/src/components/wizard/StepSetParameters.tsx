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
} from '@mui/material';
import type { TradingPair } from '../../types/exchange.ts';
import { validateParameters } from './gridParameters.ts';
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
  const stepSize = !isNaN(lower) && !isNaN(upper) && params.gridCount > 1
    ? (upper - lower) / params.gridCount
    : 0;
  const profitPerGrid = stepSize > 0 && lower > 0
    ? (stepSize / lower) * 100
    : 0;

  return (
    <Box sx={{ mt: 2 }}>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        {pair.symbol} — Last price: {pair.last_price}
      </Typography>

      <Grid container spacing={2}>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            label="Lower Price"
            value={params.lowerPrice}
            onChange={(e) => onChange({ ...params, lowerPrice: e.target.value })}
            error={!!errors.lowerPrice}
            helperText={errors.lowerPrice}
            type="number"
            fullWidth
            slotProps={{ htmlInput: { step: pair.tick_size, min: 0 } }}
          />
        </Grid>
        <Grid size={{ xs: 12, sm: 6 }}>
          <TextField
            label="Upper Price"
            value={params.upperPrice}
            onChange={(e) => onChange({ ...params, upperPrice: e.target.value })}
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
          value={params.gridCount}
          onChange={(_e, val) => onChange({ ...params, gridCount: val as number })}
          min={2}
          max={200}
          valueLabelDisplay="auto"
        />
      </Box>

      <Box sx={{ mt: 2 }}>
        <Typography gutterBottom>Spacing Type</Typography>
        <ToggleButtonGroup
          value={params.spacingType}
          exclusive
          onChange={(_e, val) => {
            if (val) onChange({ ...params, spacingType: val });
          }}
          size="small"
        >
          <ToggleButton value="arithmetic">Arithmetic</ToggleButton>
          <ToggleButton value="geometric">Geometric</ToggleButton>
        </ToggleButtonGroup>
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
          </Typography>
        </CardContent>
      </Card>
    </Box>
  );
};
