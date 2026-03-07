import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Box,
  Card,
  CardContent,
  Typography,
  TextField,
  Button,
  Alert,
  MenuItem,
  CircularProgress,
  Container,
} from '@mui/material';
import { useCreateAccount, useTestConnection } from '../api/account.ts';
import { ENVIRONMENTS } from '../types/account.ts';

export const SetupPage = () => {
  const navigate = useNavigate();
  const createAccount = useCreateAccount();
  const testConnection = useTestConnection();

  const [name, setName] = useState('My Demo Account');
  const [environment, setEnvironment] = useState('demo');
  const [apiKey, setApiKey] = useState('');
  const [apiSecret, setApiSecret] = useState('');
  const [testPassed, setTestPassed] = useState(false);

  const canTest = apiKey.trim() !== '' && apiSecret.trim() !== '';

  const handleTest = () => {
    setTestPassed(false);
    testConnection.mutate(
      { environment, api_key: apiKey, api_secret: apiSecret },
      {
        onSuccess: (result) => {
          if (result.success) {
            setTestPassed(true);
          }
        },
      },
    );
  };

  const handleSave = () => {
    createAccount.mutate(
      {
        name,
        exchange: 'bybit',
        environment,
        api_key: apiKey,
        api_secret: apiSecret,
      },
      {
        onSuccess: () => navigate('/bots'),
      },
    );
  };

  const handleKeyChange = () => {
    setTestPassed(false);
    testConnection.reset();
  };

  return (
    <Container maxWidth="sm" sx={{ mt: 8 }}>
      <Box sx={{ textAlign: 'center', mb: 4 }}>
        <Typography variant="h4" sx={{ fontWeight: 600 }}>
          GridBot
        </Typography>
        <Typography variant="body1" color="text.secondary" sx={{ mt: 1 }}>
          Connect your Bybit account to get started
        </Typography>
      </Box>

      <Card variant="outlined">
        <CardContent sx={{ p: 3 }}>
          <Typography variant="h6" sx={{ mb: 3 }}>
            Account Setup
          </Typography>

          <TextField
            data-testid="setup-name"
            label="Account Name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            fullWidth
            size="small"
            sx={{ mb: 2 }}
          />

          <TextField
            data-testid="setup-environment"
            label="Environment"
            value={environment}
            onChange={(e) => {
              setEnvironment(e.target.value);
              handleKeyChange();
            }}
            select
            fullWidth
            size="small"
            sx={{ mb: 2 }}
          >
            {ENVIRONMENTS.map((env) => (
              <MenuItem key={env.value} value={env.value}>
                {env.label}
              </MenuItem>
            ))}
          </TextField>

          <TextField
            data-testid="setup-api-key"
            label="API Key"
            value={apiKey}
            onChange={(e) => {
              setApiKey(e.target.value);
              handleKeyChange();
            }}
            fullWidth
            size="small"
            sx={{ mb: 2 }}
          />

          <TextField
            data-testid="setup-api-secret"
            label="API Secret"
            value={apiSecret}
            onChange={(e) => {
              setApiSecret(e.target.value);
              handleKeyChange();
            }}
            type="password"
            fullWidth
            size="small"
            sx={{ mb: 3 }}
          />

          {testConnection.isSuccess && (
            <Alert
              data-testid="setup-test-result"
              severity={testConnection.data.success ? 'success' : 'error'}
              sx={{ mb: 2 }}
            >
              {testConnection.data.success
                ? `Connection successful! Balance: ${testConnection.data.balance}`
                : `Connection failed: ${testConnection.data.error}`}
            </Alert>
          )}

          {testConnection.isError && (
            <Alert data-testid="setup-test-result" severity="error" sx={{ mb: 2 }}>
              Connection failed: {(testConnection.error as Error).message || 'Unknown error'}
            </Alert>
          )}

          {createAccount.isError && (
            <Alert severity="error" sx={{ mb: 2 }}>
              {(createAccount.error as Error).message || 'Failed to create account'}
            </Alert>
          )}

          <Box sx={{ display: 'flex', gap: 2, justifyContent: 'flex-end' }}>
            <Button
              data-testid="setup-test-btn"
              variant="outlined"
              onClick={handleTest}
              disabled={!canTest || testConnection.isPending}
              startIcon={testConnection.isPending ? <CircularProgress size={18} /> : undefined}
            >
              Test Connection
            </Button>
            <Button
              data-testid="setup-save-btn"
              variant="contained"
              onClick={handleSave}
              disabled={!testPassed || createAccount.isPending}
              startIcon={createAccount.isPending ? <CircularProgress size={18} /> : undefined}
            >
              Save
            </Button>
          </Box>
        </CardContent>
      </Card>
    </Container>
  );
};
