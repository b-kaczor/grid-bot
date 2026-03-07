import { Chip } from '@mui/material';
import type { Bot } from '../types/bot.ts';

const STATUS_COLORS: Record<Bot['status'], 'success' | 'warning' | 'error' | 'info' | 'default'> = {
  running: 'success',
  paused: 'warning',
  stopping: 'warning',
  stopped: 'default',
  error: 'error',
  pending: 'info',
  initializing: 'info',
};

interface StatusBadgeProps {
  status: Bot['status'];
}

export const StatusBadge = ({ status }: StatusBadgeProps) => (
  <Chip
    label={status}
    color={STATUS_COLORS[status]}
    size="small"
    variant="filled"
  />
);
