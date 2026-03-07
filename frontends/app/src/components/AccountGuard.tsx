import type { ReactNode } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { Box, CircularProgress } from '@mui/material';
import { useExchangeAccount } from '../api/account.ts';

interface AccountGuardProps {
  children: ReactNode;
}

export const AccountGuard = ({ children }: AccountGuardProps) => {
  const { data, isLoading, isError } = useExchangeAccount();
  const location = useLocation();

  if (isLoading) {
    return (
      <Box sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center', minHeight: '60vh' }}>
        <CircularProgress />
      </Box>
    );
  }

  if (isError || !data) {
    if (location.pathname === '/setup') {
      return <>{children}</>;
    }
    return <Navigate to="/setup" replace />;
  }

  return <>{children}</>;
};
