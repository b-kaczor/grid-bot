export interface GridParameters {
  lowerPrice: string;
  upperPrice: string;
  gridCount: number;
  spacingType: 'arithmetic' | 'geometric';
}

interface ValidationResult {
  lowerPrice?: string;
  upperPrice?: string;
  gridCount?: string;
}

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

  return errors;
};

export const isParametersValid = (params: GridParameters, lastPrice: string): boolean =>
  Object.keys(validateParameters(params, lastPrice)).length === 0;

export const computeDefaults = (lastPrice: string): GridParameters => {
  const price = parseFloat(lastPrice);
  return {
    lowerPrice: (price * 0.9).toFixed(2),
    upperPrice: (price * 1.1).toFixed(2),
    gridCount: 20,
    spacingType: 'arithmetic',
  };
};
