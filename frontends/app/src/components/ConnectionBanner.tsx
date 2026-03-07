import { Alert } from '@mui/material';

interface ConnectionBannerProps {
  status: 'connected' | 'disconnected';
}

export const ConnectionBanner = ({ status }: ConnectionBannerProps) => {
  if (status === 'connected') return null;

  return (
    <Alert severity="warning" sx={{ mb: 2 }}>
      Live updates disconnected. Data may be stale.
    </Alert>
  );
};
