import { useState } from 'react';
import {
  Card,
  CardContent,
  Typography,
  Box,
  Button,
  TextField,
  Switch,
  FormControlLabel,
  Alert,
  Grid,
} from '@mui/material';
import type { Bot } from '../types/bot.ts';
import { useUpdateBot } from '../api/bots.ts';

interface RiskSettingsCardProps {
  bot: Bot;
}

const formatStopReason = (reason: string): string => {
  if (reason === 'stop_loss') return 'Stop Loss triggered';
  if (reason === 'take_profit') return 'Take Profit triggered';
  return reason;
};

export const RiskSettingsCard = ({ bot }: RiskSettingsCardProps) => {
  const updateBot = useUpdateBot(bot.id);
  const [editing, setEditing] = useState(false);
  const [stopLoss, setStopLoss] = useState(bot.stop_loss_price ?? '');
  const [takeProfit, setTakeProfit] = useState(bot.take_profit_price ?? '');
  const [trailing, setTrailing] = useState(bot.trailing_up_enabled);

  const handleEdit = () => {
    setStopLoss(bot.stop_loss_price ?? '');
    setTakeProfit(bot.take_profit_price ?? '');
    setTrailing(bot.trailing_up_enabled);
    setEditing(true);
  };

  const handleCancel = () => {
    setEditing(false);
  };

  const handleSave = () => {
    updateBot.mutate(
      {
        stop_loss_price: stopLoss || null,
        take_profit_price: takeProfit || null,
        trailing_up_enabled: trailing,
      } as Partial<Bot>,
      {
        onSuccess: () => setEditing(false),
      },
    );
  };

  const isStopped = bot.status === 'stopped';
  const isStopping = bot.status === 'stopping';
  const hasRiskReason = isStopped && (bot.stop_reason === 'stop_loss' || bot.stop_reason === 'take_profit');
  const canEdit = bot.status === 'running' || bot.status === 'paused';

  return (
    <Card data-testid="risk-settings-card" variant="outlined">
      <CardContent>
        {isStopping && (
          <Alert severity="error" sx={{ mb: 2 }}>
            Emergency stop in progress — if this persists, check exchange manually
          </Alert>
        )}

        {hasRiskReason && (
          <Alert severity="warning" sx={{ mb: 2 }}>
            Stopped: {formatStopReason(bot.stop_reason!)}
          </Alert>
        )}

        <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', mb: 2 }}>
          <Typography variant="subtitle2">Risk Settings</Typography>
          {canEdit && !editing && (
            <Button size="small" onClick={handleEdit}>
              Edit
            </Button>
          )}
        </Box>

        {editing ? (
          <>
            <Grid container spacing={2}>
              <Grid size={{ xs: 12, sm: 6 }}>
                <TextField
                  data-testid="input-stop-loss"
                  label="Stop Loss Price"
                  value={stopLoss}
                  onChange={(e) => setStopLoss(e.target.value)}
                  type="number"
                  fullWidth
                  size="small"
                  helperText="Leave blank to disable"
                />
              </Grid>
              <Grid size={{ xs: 12, sm: 6 }}>
                <TextField
                  label="Take Profit Price"
                  value={takeProfit}
                  onChange={(e) => setTakeProfit(e.target.value)}
                  type="number"
                  fullWidth
                  size="small"
                  helperText="Leave blank to disable"
                />
              </Grid>
            </Grid>
            <FormControlLabel
              control={
                <Switch
                  checked={trailing}
                  onChange={(e) => setTrailing(e.target.checked)}
                />
              }
              label="Trailing Grid"
              sx={{ mt: 1 }}
            />
            <Box sx={{ display: 'flex', gap: 1, mt: 2 }}>
              <Button
                size="small"
                variant="contained"
                onClick={handleSave}
                disabled={updateBot.isPending}
              >
                Save
              </Button>
              <Button size="small" onClick={handleCancel}>
                Cancel
              </Button>
            </Box>
            {updateBot.isError && (
              <Alert severity="error" sx={{ mt: 1 }}>
                {(updateBot.error as Error).message || 'Failed to update risk settings'}
              </Alert>
            )}
          </>
        ) : (
          <Box>
            <Typography variant="body2" sx={{ mb: 0.5 }}>
              Stop Loss: {bot.stop_loss_price ? `$${bot.stop_loss_price}` : 'Not set'}
            </Typography>
            <Typography variant="body2" sx={{ mb: 0.5 }}>
              Take Profit: {bot.take_profit_price ? `$${bot.take_profit_price}` : 'Not set'}
            </Typography>
            <Typography variant="body2">
              Trailing Grid: {bot.trailing_up_enabled ? 'ON' : 'OFF'}
            </Typography>
          </Box>
        )}
      </CardContent>
    </Card>
  );
};
