import { useState } from 'react';
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
} from '@mui/material';
import { useExchangeAccount, useUpdateAccount, useTestConnection } from '../api/account.ts';
import { ENVIRONMENTS } from '../types/account.ts';

export const SettingsPage = () => {
  const { data: account, isLoading } = useExchangeAccount();
  const updateAccount = useUpdateAccount();
  const testConnection = useTestConnection();

  const [editing, setEditing] = useState(false);
  const [name, setName] = useState('');
  const [environment, setEnvironment] = useState('');
  const [apiKey, setApiKey] = useState('');
  const [apiSecret, setApiSecret] = useState('');
  const [testPassed, setTestPassed] = useState(false);
  const [saveSuccess, setSaveSuccess] = useState(false);

  const hasNewKeys = apiKey.trim() !== '' || apiSecret.trim() !== '';
  const needsTest = hasNewKeys && !testPassed;
  const canSave = name.trim() !== '' && !needsTest;

  const handleEdit = () => {
    if (!account) return;
    setName(account.name);
    setEnvironment(account.environment);
    setApiKey('');
    setApiSecret('');
    setTestPassed(false);
    setSaveSuccess(false);
    testConnection.reset();
    updateAccount.reset();
    setEditing(true);
  };

  const handleCancel = () => {
    setEditing(false);
    testConnection.reset();
    updateAccount.reset();
  };

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
    const data: Record<string, string> = { name, environment };
    if (apiKey.trim()) data.api_key = apiKey;
    if (apiSecret.trim()) data.api_secret = apiSecret;

    updateAccount.mutate(data, {
      onSuccess: () => {
        setEditing(false);
        setSaveSuccess(true);
      },
    });
  };

  const handleKeyChange = () => {
    setTestPassed(false);
    testConnection.reset();
  };

  if (isLoading) {
    return (
      <Box sx={{ display: 'flex', justifyContent: 'center', mt: 4 }}>
        <CircularProgress />
      </Box>
    );
  }

  if (!account) {
    return (
      <Alert severity="warning">No account found.</Alert>
    );
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 3 }}>
        Settings
      </Typography>

      {saveSuccess && !editing && (
        <Alert severity="success" sx={{ mb: 2 }} onClose={() => setSaveSuccess(false)}>
          Account updated successfully.
        </Alert>
      )}

      <Card data-testid="settings-card" variant="outlined">
        <CardContent>
          <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', mb: 2 }}>
            <Typography variant="subtitle2">Exchange Account</Typography>
            {!editing && (
              <Button data-testid="settings-edit-btn" size="small" onClick={handleEdit}>
                Edit
              </Button>
            )}
          </Box>

          {editing ? (
            <>
              <TextField
                data-testid="settings-name"
                label="Account Name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                fullWidth
                size="small"
                sx={{ mb: 2 }}
              />

              <TextField
                data-testid="settings-environment"
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
                data-testid="settings-api-key"
                label="API Key"
                value={apiKey}
                onChange={(e) => {
                  setApiKey(e.target.value);
                  handleKeyChange();
                }}
                placeholder={account.api_key_hint}
                fullWidth
                size="small"
                helperText="Leave blank to keep current key"
                sx={{ mb: 2 }}
              />

              <TextField
                data-testid="settings-api-secret"
                label="API Secret"
                value={apiSecret}
                onChange={(e) => {
                  setApiSecret(e.target.value);
                  handleKeyChange();
                }}
                type="password"
                placeholder="Enter new secret"
                fullWidth
                size="small"
                helperText="Leave blank to keep current secret"
                sx={{ mb: 3 }}
              />

              {testConnection.isSuccess && (
                <Alert
                  data-testid="settings-test-result"
                  severity={testConnection.data.success ? 'success' : 'error'}
                  sx={{ mb: 2 }}
                >
                  {testConnection.data.success
                    ? `Connection successful! Balance: ${testConnection.data.balance}`
                    : `Connection failed: ${testConnection.data.error}`}
                </Alert>
              )}

              {testConnection.isError && (
                <Alert severity="error" sx={{ mb: 2 }}>
                  Connection failed: {(testConnection.error as Error).message || 'Unknown error'}
                </Alert>
              )}

              {updateAccount.isError && (
                <Alert severity="error" sx={{ mb: 2 }}>
                  {(updateAccount.error as Error).message || 'Failed to update account'}
                </Alert>
              )}

              <Box sx={{ display: 'flex', gap: 1 }}>
                {hasNewKeys && (
                  <Button
                    data-testid="settings-test-btn"
                    variant="outlined"
                    size="small"
                    onClick={handleTest}
                    disabled={!apiKey.trim() || !apiSecret.trim() || testConnection.isPending}
                    startIcon={testConnection.isPending ? <CircularProgress size={18} /> : undefined}
                  >
                    Test Connection
                  </Button>
                )}
                <Button
                  data-testid="settings-save-btn"
                  size="small"
                  variant="contained"
                  onClick={handleSave}
                  disabled={!canSave || updateAccount.isPending}
                  startIcon={updateAccount.isPending ? <CircularProgress size={18} /> : undefined}
                >
                  Save
                </Button>
                <Button data-testid="settings-cancel-btn" size="small" onClick={handleCancel}>
                  Cancel
                </Button>
              </Box>
            </>
          ) : (
            <Box>
              <Typography variant="body2" sx={{ mb: 0.5 }}>
                Name: {account.name}
              </Typography>
              <Typography variant="body2" sx={{ mb: 0.5 }}>
                Exchange: {account.exchange}
              </Typography>
              <Typography variant="body2" sx={{ mb: 0.5 }}>
                Environment: {account.environment}
              </Typography>
              <Typography variant="body2">
                API Key: {account.api_key_hint}
              </Typography>
            </Box>
          )}
        </CardContent>
      </Card>
    </Box>
  );
};
