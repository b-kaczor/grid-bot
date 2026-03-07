import type { ReactNode } from 'react';
import { AppBar, Toolbar, Typography, Container, Box } from '@mui/material';
import { useNavigate } from 'react-router-dom';

interface AppLayoutProps {
  children: ReactNode;
}

export const AppLayout = ({ children }: AppLayoutProps) => {
  const navigate = useNavigate();

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', minHeight: '100vh' }}>
      <AppBar position="static" color="default" elevation={1}>
        <Toolbar>
          <Typography
            variant="h6"
            component="div"
            sx={{ cursor: 'pointer', flexGrow: 1 }}
            onClick={() => navigate('/bots')}
          >
            GridBot
          </Typography>
        </Toolbar>
      </AppBar>
      <Container maxWidth="lg" sx={{ mt: 3, mb: 3, flexGrow: 1 }}>
        {children}
      </Container>
    </Box>
  );
};
