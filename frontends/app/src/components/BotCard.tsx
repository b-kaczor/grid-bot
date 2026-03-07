import { Card, CardContent, CardActionArea, Box, Typography, Stack } from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { StatusBadge } from './StatusBadge.tsx';
import { RangeVisualizer } from './RangeVisualizer.tsx';
import type { Bot } from '../types/bot.ts';

interface BotCardProps {
  bot: Bot;
}

const formatUptime = (seconds?: number): string => {
  if (!seconds || seconds <= 0) return '0m';
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const parts: string[] = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (minutes > 0 || parts.length === 0) parts.push(`${minutes}m`);
  return parts.join(' ');
};

const computeDailyApr = (bot: Bot): string | null => {
  const profit = parseFloat(bot.realized_profit ?? '0');
  const investment = parseFloat(bot.investment_amount);
  const seconds = bot.uptime_seconds ?? 0;
  if (investment <= 0 || seconds <= 0) return null;
  const days = seconds / 86400;
  const apr = (profit / investment) * (365 / days) * 100;
  return apr.toFixed(2);
};

export const BotCard = ({ bot }: BotCardProps) => {
  const navigate = useNavigate();
  const dailyApr = computeDailyApr(bot);

  return (
    <Card>
      <CardActionArea onClick={() => navigate(`/bots/${bot.id}`)}>
        <CardContent>
          <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1.5 }}>
            <Typography variant="h6">{bot.pair}</Typography>
            <StatusBadge status={bot.status} />
          </Box>

          <RangeVisualizer
            lowerPrice={bot.lower_price}
            upperPrice={bot.upper_price}
            currentPrice={bot.current_price}
          />

          <Stack direction="row" justifyContent="space-between" sx={{ mt: 2 }}>
            <Box>
              <Typography variant="caption" color="text.secondary">
                Profit
              </Typography>
              <Typography variant="body2" sx={{ color: 'primary.main', fontWeight: 600 }}>
                {bot.realized_profit ?? '0'} {bot.quote_coin}
              </Typography>
            </Box>
            <Box sx={{ textAlign: 'center' }}>
              <Typography variant="caption" color="text.secondary">
                Trades
              </Typography>
              <Typography variant="body2">{bot.trade_count ?? 0}</Typography>
            </Box>
            <Box sx={{ textAlign: 'right' }}>
              <Typography variant="caption" color="text.secondary">
                Daily APR
              </Typography>
              <Typography variant="body2">
                {dailyApr !== null ? `${dailyApr}%` : '--'}
              </Typography>
            </Box>
          </Stack>

          <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1 }}>
            Uptime: {formatUptime(bot.uptime_seconds)}
          </Typography>
        </CardContent>
      </CardActionArea>
    </Card>
  );
};
