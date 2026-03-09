export interface GridParameters {
  lowerPrice: string;
  upperPrice: string;
  gridCount: number;
  spacingType: 'arithmetic' | 'geometric';
  stopLossPrice: string;
  takeProfitPrice: string;
  trailingUpEnabled: boolean;
  targetProfitPct: string;
}

interface ValidationResult {
  lowerPrice?: string;
  upperPrice?: string;
  gridCount?: string;
  stopLossPrice?: string;
  takeProfitPrice?: string;
  targetProfitPct?: string;
}

// Given lowerPrice, upperPrice, targetProfitPct → derived gridCount
export const deriveGridCount = (lower: number, upper: number, pct: number, spacing: 'arithmetic' | 'geometric' = 'geometric'): number => {
  if (spacing === 'geometric') {
    return Math.round(Math.log(upper / lower) / Math.log(1 + pct / 100));
  }
  return Math.round((upper - lower) / (lower * (pct / 100)));
};

export const validateParameters = (params: GridParameters, lastPrice: string): ValidationResult => {
  const errors: ValidationResult = {};
  const lower = parseFloat(params.lowerPrice);
  const upper = parseFloat(params.upperPrice);
  const current = parseFloat(lastPrice);

  if (isNaN(lower) || lower <= 0) {
    errors.lowerPrice = 'Must be a positive number';
  } else if (lower >= current) {
    errors.lowerPrice = 'Must be below current price';
  }

  if (isNaN(upper) || upper <= 0) {
    errors.upperPrice = 'Must be a positive number';
  } else if (upper <= current) {
    errors.upperPrice = 'Must be above current price';
  }

  if (!isNaN(lower) && !isNaN(upper) && lower >= upper) {
    errors.upperPrice = 'Must be greater than lower price';
  }

  if (params.gridCount < 2) {
    errors.gridCount = 'Minimum 2 grid levels';
  }

  if (params.stopLossPrice !== '') {
    const sl = parseFloat(params.stopLossPrice);
    if (isNaN(sl) || sl <= 0) {
      errors.stopLossPrice = 'Must be a positive number';
    } else if (!isNaN(lower) && sl >= lower) {
      errors.stopLossPrice = 'Must be below lower price';
    }
  }

  if (params.takeProfitPrice !== '') {
    const tp = parseFloat(params.takeProfitPrice);
    if (isNaN(tp) || tp <= 0) {
      errors.takeProfitPrice = 'Must be a positive number';
    } else if (!isNaN(upper) && tp <= upper) {
      errors.takeProfitPrice = 'Must be above upper price';
    }
  }

  if (params.targetProfitPct !== '') {
    const pct = parseFloat(params.targetProfitPct);
    if (isNaN(pct) || pct <= 0) {
      errors.targetProfitPct = 'Must be greater than 0';
    } else if (pct >= 100) {
      errors.targetProfitPct = 'Must be less than 100';
    } else if (!isNaN(lower) && !isNaN(upper) && lower > 0 && upper > lower) {
      const derived = deriveGridCount(lower, upper, pct, params.spacingType);
      if (derived < 2) {
        errors.targetProfitPct = 'Profit target too large — requires fewer than 2 levels';
      }
    }
  }

  return errors;
};

export const isParametersValid = (params: GridParameters, lastPrice: string): boolean =>
  Object.keys(validateParameters(params, lastPrice)).length === 0;

export const getProfitTargetWarning = (params: GridParameters): string | null => {
  if (params.targetProfitPct === '') return null;
  const pct = parseFloat(params.targetProfitPct);
  if (isNaN(pct) || pct <= 0) return null;

  const lower = parseFloat(params.lowerPrice);
  const upper = parseFloat(params.upperPrice);
  if (!isNaN(lower) && !isNaN(upper) && lower > 0 && upper > lower) {
    const derived = deriveGridCount(lower, upper, pct, params.spacingType);
    if (derived > 200) {
      return `Target requires ${derived} levels — exceeds max of 200. Grid count capped at 200.`;
    }
  }

  return null;
};

export const computeDefaults = (lastPrice: string): GridParameters => {
  const price = parseFloat(lastPrice);
  return {
    lowerPrice: (price * 0.9).toFixed(2),
    upperPrice: (price * 1.1).toFixed(2),
    gridCount: 20,
    spacingType: 'geometric',
    stopLossPrice: '',
    takeProfitPrice: '',
    trailingUpEnabled: false,
    targetProfitPct: '',
  };
};
