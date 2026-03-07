import { Box, Typography, Skeleton } from '@mui/material';
import { useBotGrid } from '../api/bots.ts';
import type { GridLevel } from '../types/bot.ts';

interface GridVisualizationProps {
  botId: number;
}

const LEVEL_HEIGHT = 28;
const LABEL_WIDTH = 90;
const BADGE_WIDTH = 40;

const levelColor = (level: GridLevel): string => {
  if (level.status === 'filled' || level.status === 'pending') return '#555';
  return level.expected_side === 'buy' ? '#4caf50' : '#f44336';
};

const levelOpacity = (level: GridLevel): number =>
  level.status === 'active' ? 1 : 0.4;

export const GridVisualization = ({ botId }: GridVisualizationProps) => {
  const { data: grid, isLoading } = useBotGrid(botId);

  if (isLoading) {
    return (
      <Box>
        {Array.from({ length: 10 }).map((_, i) => (
          <Skeleton key={i} variant="rectangular" height={LEVEL_HEIGHT - 4} sx={{ mb: '4px' }} />
        ))}
      </Box>
    );
  }

  if (!grid?.levels.length) {
    return (
      <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: 'center' }}>
        Not enough data yet.
      </Typography>
    );
  }

  const levels = [...grid.levels].sort((a, b) => parseFloat(b.price) - parseFloat(a.price));
  const currentPrice = grid.current_price ? parseFloat(grid.current_price) : null;

  return (
    <Box sx={{ maxHeight: 500, overflow: 'auto', position: 'relative' }}>
      {levels.map((level) => {
        const isAtCurrentPrice =
          currentPrice !== null &&
          Math.abs(parseFloat(level.price) - currentPrice) / currentPrice < 0.001;

        return (
          <Box
            key={level.level_index}
            sx={{
              display: 'flex',
              alignItems: 'center',
              height: LEVEL_HEIGHT,
              borderBottom: '1px solid',
              borderColor: 'divider',
              position: 'relative',
            }}
          >
            {/* Price label */}
            <Typography
              variant="caption"
              sx={{ width: LABEL_WIDTH, textAlign: 'right', pr: 1, flexShrink: 0 }}
            >
              {level.price}
            </Typography>

            {/* Bar */}
            <Box
              sx={{
                flex: 1,
                height: 12,
                borderRadius: 1,
                backgroundColor: levelColor(level),
                opacity: levelOpacity(level),
                mx: 1,
              }}
            />

            {/* Cycle count badge */}
            <Typography
              variant="caption"
              color="text.secondary"
              sx={{ width: BADGE_WIDTH, textAlign: 'center', flexShrink: 0 }}
            >
              {level.cycle_count > 0 ? `x${level.cycle_count}` : ''}
            </Typography>

            {/* Current price marker */}
            {isAtCurrentPrice && (
              <Box
                sx={{
                  position: 'absolute',
                  left: LABEL_WIDTH,
                  right: BADGE_WIDTH,
                  top: '50%',
                  height: 2,
                  backgroundColor: 'warning.main',
                  pointerEvents: 'none',
                }}
              />
            )}
          </Box>
        );
      })}

      {/* Floating current price label */}
      {currentPrice !== null && (
        <Box sx={{ mt: 1, display: 'flex', justifyContent: 'center' }}>
          <Typography variant="caption" color="warning.main">
            Current: {grid.current_price}
          </Typography>
        </Box>
      )}
    </Box>
  );
};
