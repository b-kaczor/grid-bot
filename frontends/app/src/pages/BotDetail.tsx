import { useParams, useNavigate } from 'react-router-dom';
import {
  Typography,
  Box,
  Card,
  CardContent,
  Button,
  Grid,
  Skeleton,
  Alert,
  CircularProgress,
} from '@mui/material';
import { useBot, useUpdateBot, useDeleteBot } from '../api/bots.ts';
import { useBotChannel } from '../cable/useBotChannel.ts';
import { StatusBadge } from '../components/StatusBadge.tsx';
import { ConnectionBanner } from '../components/ConnectionBanner.tsx';
import { TradeHistoryTable } from '../components/TradeHistoryTable.tsx';
import { GridVisualization } from '../components/GridVisualization.tsx';
import { PerformanceCharts } from '../components/PerformanceCharts.tsx';
import { RiskSettingsCard } from '../components/RiskSettingsCard.tsx';

const formatUptime = (seconds: number): string => {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const parts: string[] = [];
  if (d > 0) parts.push(`${d}d`);
  if (h > 0) parts.push(`${h}h`);
  parts.push(`${m}m`);
  return parts.join(' ');
};

interface StatCardProps {
  label: string;
  value: string;
  color?: string;
}

const StatCard = ({ label, value, color }: StatCardProps) => (
  <Card variant="outlined">
    <CardContent sx={{ textAlign: 'center', py: 2 }}>
      <Typography variant="caption" color="text.secondary">
        {label}
      </Typography>
      <Typography variant="h6" color={color ?? 'text.primary'}>
        {value}
      </Typography>
    </CardContent>
  </Card>
);

export const BotDetail = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const botId = Number(id);
  const { data: bot, isLoading, isError } = useBot(botId);
  const { connectionStatus } = useBotChannel(botId);
  const updateBot = useUpdateBot(botId);
  const deleteBot = useDeleteBot();

  if (isLoading) {
    return (
      <Box>
        <Skeleton variant="text" width={300} height={40} />
        <Grid container spacing={2} sx={{ mt: 2 }}>
          {Array.from({ length: 4 }).map((_, i) => (
            <Grid key={i} size={{ xs: 6, md: 3 }}>
              <Skeleton variant="rounded" height={80} />
            </Grid>
          ))}
        </Grid>
      </Box>
    );
  }

  if (isError || !bot) {
    return <Alert severity="error">Failed to load bot details.</Alert>;
  }

  const isRunning = bot.status === 'running';
  const isPaused = bot.status === 'paused';
  const canStop = isRunning || isPaused;
  const isInitializing = bot.status === 'pending' || bot.status === 'initializing';

  const handleStop = () => updateBot.mutate({ status: 'stopped' } as never);
  const handlePause = () => updateBot.mutate({ status: 'paused' } as never);
  const handleResume = () => updateBot.mutate({ status: 'running' } as never);
  const handleDelete = () => {
    deleteBot.mutate(botId, {
      onSuccess: () => navigate('/bots'),
    });
  };

  return (
    <Box>
      <ConnectionBanner status={connectionStatus} />

      {/* Header */}
      <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', mb: 3 }}>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 2 }}>
          <Typography variant="h5">{bot.pair}</Typography>
          <StatusBadge status={bot.status} />
          {bot.uptime_seconds != null && bot.uptime_seconds > 0 && (
            <Typography variant="body2" color="text.secondary">
              {formatUptime(bot.uptime_seconds)}
            </Typography>
          )}
        </Box>
        <Box sx={{ display: 'flex', gap: 1 }}>
          {isRunning && (
            <Button
              size="small"
              variant="outlined"
              color="warning"
              onClick={handlePause}
              disabled={updateBot.isPending}
            >
              Pause
            </Button>
          )}
          {isPaused && (
            <Button
              size="small"
              variant="outlined"
              color="primary"
              onClick={handleResume}
              disabled={updateBot.isPending}
            >
              Resume
            </Button>
          )}
          {canStop && (
            <Button
              size="small"
              variant="outlined"
              color="error"
              onClick={handleStop}
              disabled={updateBot.isPending}
            >
              Stop
            </Button>
          )}
          {bot.status === 'stopped' && (
            <Button
              size="small"
              variant="outlined"
              color="error"
              onClick={handleDelete}
              disabled={deleteBot.isPending}
            >
              Delete
            </Button>
          )}
        </Box>
      </Box>

      {/* Initializing state */}
      {isInitializing && (
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, py: 4, justifyContent: 'center' }}>
          <CircularProgress size={24} />
          <Typography>Setting up your bot...</Typography>
        </Box>
      )}

      {/* Error state (non-risk) */}
      {bot.status === 'error' && (
        <Alert severity="error" sx={{ mb: 2 }}>
          Bot encountered an error and has stopped.
        </Alert>
      )}

      {/* Stats Row */}
      {!isInitializing && (
        <>
          <Grid container spacing={2} sx={{ mb: 3 }}>
            <Grid size={{ xs: 6, md: 3 }}>
              <StatCard
                label="Realized Profit"
                value={bot.realized_profit ?? '0'}
                color="success.main"
              />
            </Grid>
            <Grid size={{ xs: 6, md: 3 }}>
              <StatCard
                label="Unrealized PnL"
                value={bot.unrealized_pnl ?? '0'}
              />
            </Grid>
            <Grid size={{ xs: 6, md: 3 }}>
              <StatCard
                label="Trade Count"
                value={String(bot.trade_count ?? 0)}
              />
            </Grid>
            <Grid size={{ xs: 6, md: 3 }}>
              <StatCard
                label="Active Levels"
                value={String(bot.active_levels ?? 0)}
              />
            </Grid>
          </Grid>

          {/* Risk Settings */}
          <Box sx={{ mb: 3 }}>
            <RiskSettingsCard bot={bot} />
          </Box>

          {/* Grid Visualization + Performance Charts */}
          <Grid container spacing={2} sx={{ mb: 3 }}>
            <Grid size={{ xs: 12, md: 6 }}>
              <Card variant="outlined">
                <CardContent>
                  <Typography variant="subtitle2" sx={{ mb: 1 }}>Grid Levels</Typography>
                  <GridVisualization botId={botId} />
                </CardContent>
              </Card>
            </Grid>
            <Grid size={{ xs: 12, md: 6 }}>
              <PerformanceCharts botId={botId} />
            </Grid>
          </Grid>

          {/* Trade History */}
          <Typography variant="h6" sx={{ mb: 2 }}>
            Trade History
          </Typography>
          <TradeHistoryTable botId={botId} />
        </>
      )}
    </Box>
  );
};
