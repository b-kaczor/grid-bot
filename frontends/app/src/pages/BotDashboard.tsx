import { Box, Typography, Grid, Skeleton, Alert, Card, CardContent, Fab } from '@mui/material';
import AddIcon from '@mui/icons-material/Add';
import { useNavigate } from 'react-router-dom';
import { useBots } from '../api/bots.ts';
import { BotCard } from '../components/BotCard.tsx';

export const BotDashboard = () => {
  const navigate = useNavigate();
  const { data: bots, isLoading, isError, refetch } = useBots();

  if (isLoading) {
    return (
      <Grid container spacing={3}>
        {[0, 1, 2].map((i) => (
          <Grid size={{ xs: 12, sm: 6, md: 4 }} key={i}>
            <Card>
              <CardContent>
                <Skeleton variant="text" width="60%" height={32} />
                <Skeleton variant="rectangular" height={8} sx={{ my: 2, borderRadius: 4 }} />
                <Skeleton variant="text" width="100%" />
                <Skeleton variant="text" width="80%" />
              </CardContent>
            </Card>
          </Grid>
        ))}
      </Grid>
    );
  }

  if (isError) {
    return (
      <Alert severity="error" action={<Typography sx={{ cursor: 'pointer', textDecoration: 'underline' }} onClick={() => refetch()}>Retry</Typography>}>
        Failed to load bots. Please check your connection.
      </Alert>
    );
  }

  if (!bots || bots.length === 0) {
    return (
      <Box sx={{ textAlign: 'center', mt: 8 }}>
        <Typography variant="h5" gutterBottom>
          No bots yet
        </Typography>
        <Typography variant="body1" color="text.secondary" sx={{ mb: 3 }}>
          Create your first grid trading bot to get started.
        </Typography>
        <Fab variant="extended" color="primary" onClick={() => navigate('/bots/new')}>
          <AddIcon sx={{ mr: 1 }} />
          Create Bot
        </Fab>
      </Box>
    );
  }

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 3 }}>
        <Typography variant="h5">Your Bots</Typography>
      </Box>

      <Grid container spacing={3}>
        {bots.map((bot) => (
          <Grid size={{ xs: 12, sm: 6, md: 4 }} key={bot.id}>
            <BotCard bot={bot} />
          </Grid>
        ))}
      </Grid>

      <Fab
        color="primary"
        sx={{ position: 'fixed', bottom: 24, right: 24 }}
        onClick={() => navigate('/bots/new')}
      >
        <AddIcon />
      </Fab>
    </Box>
  );
};
