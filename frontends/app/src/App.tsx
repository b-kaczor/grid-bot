import { BrowserRouter, Routes, Route, Navigate, Outlet } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ThemeProvider, CssBaseline } from '@mui/material';
import theme from './theme/index.ts';
import { AppLayout } from './components/AppLayout.tsx';
import { AccountGuard } from './components/AccountGuard.tsx';
import { BotDashboard } from './pages/BotDashboard.tsx';
import { CreateBotWizard } from './pages/CreateBotWizard.tsx';
import { BotDetail } from './pages/BotDetail.tsx';
import { SetupPage } from './pages/SetupPage.tsx';
import { SettingsPage } from './pages/SettingsPage.tsx';

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
        <Routes>
          <Route path="/setup" element={<SetupPage />} />
          <Route
            element={
              <AccountGuard>
                <AppLayout>
                  <Outlet />
                </AppLayout>
              </AccountGuard>
            }
          >
            <Route path="/" element={<Navigate to="/bots" replace />} />
            <Route path="/bots" element={<BotDashboard />} />
            <Route path="/bots/new" element={<CreateBotWizard />} />
            <Route path="/bots/:id" element={<BotDetail />} />
            <Route path="/settings" element={<SettingsPage />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </ThemeProvider>
  </QueryClientProvider>
);
