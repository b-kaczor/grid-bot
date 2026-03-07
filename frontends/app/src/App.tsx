import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ThemeProvider, CssBaseline } from '@mui/material';
import theme from './theme/index.ts';
import { AppLayout } from './components/AppLayout.tsx';
import { BotDashboard } from './pages/BotDashboard.tsx';
import { CreateBotWizard } from './pages/CreateBotWizard.tsx';
import { BotDetail } from './pages/BotDetail.tsx';

const isTestMode = import.meta.env.VITE_TEST_MODE === '1';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: isTestMode ? 0 : 30_000,
      retry: isTestMode ? 0 : 1,
    },
  },
});

export const App = () => (
  <QueryClientProvider client={queryClient}>
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <BrowserRouter>
        <AppLayout>
          <Routes>
            <Route path="/" element={<Navigate to="/bots" replace />} />
            <Route path="/bots" element={<BotDashboard />} />
            <Route path="/bots/new" element={<CreateBotWizard />} />
            <Route path="/bots/:id" element={<BotDetail />} />
          </Routes>
        </AppLayout>
      </BrowserRouter>
    </ThemeProvider>
  </QueryClientProvider>
);
