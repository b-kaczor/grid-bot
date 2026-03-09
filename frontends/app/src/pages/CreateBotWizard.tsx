import { useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Stepper,
  Step,
  StepLabel,
  Button,
  Box,
  Typography,
  Alert,
  CircularProgress,
} from '@mui/material';
import { useCreateBot } from '../api/bots.ts';
import { useExchangeBalance } from '../api/exchange.ts';
import type { TradingPair } from '../types/exchange.ts';
import { StepSelectPair } from '../components/wizard/StepSelectPair.tsx';
import { StepSetParameters } from '../components/wizard/StepSetParameters.tsx';
import { StepInvestment } from '../components/wizard/StepInvestment.tsx';
import { isParametersValid, computeDefaults } from '../components/wizard/gridParameters.ts';
import type { GridParameters } from '../components/wizard/gridParameters.ts';

const STEPS = ['Select Pair', 'Set Parameters', 'Investment'];

export const CreateBotWizard = () => {
  const navigate = useNavigate();
  const createBot = useCreateBot();

  const [activeStep, setActiveStep] = useState(0);
  const [selectedPair, setSelectedPair] = useState<TradingPair | null>(null);
  const [params, setParams] = useState<GridParameters>({
    lowerPrice: '',
    upperPrice: '',
    gridCount: 20,
    spacingType: 'geometric',
    stopLossPrice: '',
    takeProfitPrice: '',
    trailingUpEnabled: false,
    targetProfitPct: '',
  });
  const [investmentAmount, setInvestmentAmount] = useState('');

  const handleParamsChange = useCallback((next: GridParameters) => {
    setParams(next);
  }, []);

  const canAdvance = (): boolean => {
    if (activeStep === 0) return selectedPair !== null;
    if (activeStep === 1) return selectedPair !== null && isParametersValid(params, selectedPair.last_price);
    return true;
  };

  const handleNext = () => {
    if (activeStep === 0 && selectedPair && params.lowerPrice === '') {
      setParams(computeDefaults(selectedPair.last_price));
    }
    if (activeStep === 1 && investmentAmount === '' && balances) {
      const usdtBalance = balances.find((b) => b.coin === 'USDT');
      const available = parseFloat(usdtBalance?.available ?? '0');
      setInvestmentAmount((available * 0.5).toFixed(2));
    }
    if (activeStep < STEPS.length - 1) {
      setActiveStep((s) => s + 1);
    }
  };

  const handleBack = () => {
    setActiveStep((s) => s - 1);
  };

  const { data: balances } = useExchangeBalance();

  const computeInvestmentAmount = (): string => {
    const usdtBalance = balances?.find((b) => b.coin === 'USDT');
    const available = parseFloat(usdtBalance?.available ?? '0');
    const amount = parseFloat(investmentAmount) || 0;
    return Math.min(Math.max(amount, 0), available).toFixed(2);
  };

  const handleSubmit = () => {
    if (!selectedPair) return;

    createBot.mutate(
      {
        pair: selectedPair.symbol,
        base_coin: selectedPair.base_coin,
        quote_coin: selectedPair.quote_coin,
        lower_price: params.lowerPrice,
        upper_price: params.upperPrice,
        grid_count: params.gridCount,
        spacing_type: params.spacingType,
        investment_amount: computeInvestmentAmount(),
        stop_loss_price: params.stopLossPrice || undefined,
        take_profit_price: params.takeProfitPrice || undefined,
        trailing_up_enabled: params.trailingUpEnabled,
      },
      {
        onSuccess: (response) => {
          const botId = response.data?.bot?.id;
          navigate(botId ? `/bots/${botId}` : '/bots');
        },
      },
    );
  };

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 3 }}>
        Create Bot
      </Typography>

      <Stepper activeStep={activeStep} sx={{ mb: 4 }}>
        {STEPS.map((label) => (
          <Step key={label}>
            <StepLabel>{label}</StepLabel>
          </Step>
        ))}
      </Stepper>

      {createBot.isError && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {(createBot.error as Error).message || 'Failed to create bot. Please try again.'}
        </Alert>
      )}

      {activeStep === 0 && (
        <Box data-testid="wizard-step-0">
          <StepSelectPair selectedPair={selectedPair} onSelect={setSelectedPair} />
        </Box>
      )}

      {activeStep === 1 && selectedPair && (
        <Box data-testid="wizard-step-1">
          <StepSetParameters pair={selectedPair} params={params} onChange={handleParamsChange} />
        </Box>
      )}

      {activeStep === 2 && selectedPair && (
        <Box data-testid="wizard-step-2">
          <StepInvestment
            pair={selectedPair}
            params={params}
            investmentAmount={investmentAmount}
            onInvestmentAmountChange={setInvestmentAmount}
          />
        </Box>
      )}

      <Box sx={{ display: 'flex', justifyContent: 'space-between', mt: 4 }}>
        <Button disabled={activeStep === 0} onClick={handleBack}>
          Back
        </Button>

        {activeStep < STEPS.length - 1 ? (
          <Button variant="contained" disabled={!canAdvance()} onClick={handleNext}>
            Next
          </Button>
        ) : (
          <Button
            variant="contained"
            color="primary"
            disabled={createBot.isPending}
            onClick={handleSubmit}
            startIcon={createBot.isPending ? <CircularProgress size={18} /> : undefined}
          >
            Create Bot
          </Button>
        )}
      </Box>
    </Box>
  );
};
