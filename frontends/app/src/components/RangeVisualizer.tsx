import { Box, Typography } from '@mui/material';

interface RangeVisualizerProps {
  lowerPrice: string;
  upperPrice: string;
  currentPrice?: string;
}

const getPositionPercent = (current: number, lower: number, upper: number): number => {
  if (upper === lower) return 50;
  const pct = ((current - lower) / (upper - lower)) * 100;
  return Math.max(0, Math.min(100, pct));
};

const getBarColor = (pct: number): string => {
  if (pct <= 0 || pct >= 100) return '#f44336';
  if (pct < 10 || pct > 90) return '#ff9800';
  return '#4caf50';
};

export const RangeVisualizer = ({ lowerPrice, upperPrice, currentPrice }: RangeVisualizerProps) => {
  const lower = parseFloat(lowerPrice);
  const upper = parseFloat(upperPrice);
  const current = currentPrice ? parseFloat(currentPrice) : null;
  const pct = current !== null ? getPositionPercent(current, lower, upper) : null;
  const color = pct !== null ? getBarColor(pct) : '#666';

  return (
    <Box data-testid="range-visualizer" sx={{ width: '100%' }}>
      <Box
        sx={{
          position: 'relative',
          height: 8,
          borderRadius: 4,
          bgcolor: 'grey.800',
          overflow: 'visible',
        }}
      >
        {pct !== null && (
          <Box
            sx={{
              position: 'absolute',
              left: `${pct}%`,
              top: '50%',
              transform: 'translate(-50%, -50%)',
              width: 12,
              height: 12,
              borderRadius: '50%',
              bgcolor: color,
            }}
          />
        )}
      </Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', mt: 0.5 }}>
        <Typography variant="caption" color="text.secondary">
          {lowerPrice}
        </Typography>
        {current !== null && (
          <Typography variant="caption" sx={{ color }}>
            {currentPrice}
          </Typography>
        )}
        <Typography variant="caption" color="text.secondary">
          {upperPrice}
        </Typography>
      </Box>
    </Box>
  );
};
