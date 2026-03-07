import { Box, Typography, Card, CardContent } from '@mui/material';
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  Area,
  AreaChart,
  Cell,
} from 'recharts';
import { useBotChart } from '../api/bots.ts';

interface PerformanceChartsProps {
  botId: number;
}

const formatDate = (iso: string): string => {
  const d = new Date(iso);
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
};

const formatDateTime = (iso: string): string => {
  const d = new Date(iso);
  return d.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
};

interface DailyProfit {
  date: string;
  profit: number;
}

export const PerformanceCharts = ({ botId }: PerformanceChartsProps) => {
  const { data, isLoading } = useBotChart(botId);

  if (isLoading) {
    return <Typography variant="body2" color="text.secondary">Loading charts...</Typography>;
  }

  if (!data?.snapshots?.length || data.snapshots.length < 2) {
    return (
      <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: 'center' }}>
        Not enough data yet. Charts appear after the first few minutes of running.
      </Typography>
    );
  }

  const equityData = data.snapshots.map((s) => ({
    time: formatDateTime(s.snapshot_at),
    value: parseFloat(s.total_value_quote),
  }));

  // Compute daily profit from consecutive snapshot differences in realized_profit
  const dailyProfitMap = new Map<string, number>();
  for (let i = 1; i < data.snapshots.length; i++) {
    const date = formatDate(data.snapshots[i].snapshot_at);
    const delta =
      parseFloat(data.snapshots[i].realized_profit) -
      parseFloat(data.snapshots[i - 1].realized_profit);
    dailyProfitMap.set(date, (dailyProfitMap.get(date) ?? 0) + delta);
  }
  const dailyProfitData: DailyProfit[] = Array.from(dailyProfitMap.entries()).map(
    ([date, profit]) => ({ date, profit: Number(profit.toFixed(4)) }),
  );

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', gap: 2, height: '100%' }}>
      {/* Equity Curve */}
      <Card data-testid="chart-portfolio" variant="outlined" sx={{ flex: 1 }}>
        <CardContent sx={{ pb: 1 }}>
          <Typography variant="subtitle2" gutterBottom>Equity Curve</Typography>
          <ResponsiveContainer width="100%" height={120}>
            <AreaChart data={equityData}>
              <XAxis dataKey="time" tick={{ fontSize: 10 }} interval="preserveStartEnd" />
              <YAxis tick={{ fontSize: 10 }} domain={['auto', 'auto']} />
              <Tooltip />
              <Area
                type="monotone"
                dataKey="value"
                stroke="#4caf50"
                fill="#4caf50"
                fillOpacity={0.15}
              />
            </AreaChart>
          </ResponsiveContainer>
        </CardContent>
      </Card>

      {/* Daily Profit */}
      {dailyProfitData.length > 0 && (
        <Card data-testid="chart-daily-profit" variant="outlined" sx={{ flex: 1 }}>
          <CardContent sx={{ pb: 1 }}>
            <Typography variant="subtitle2" gutterBottom>Daily Profit</Typography>
            <ResponsiveContainer width="100%" height={120}>
              <BarChart data={dailyProfitData}>
                <XAxis dataKey="date" tick={{ fontSize: 10 }} />
                <YAxis tick={{ fontSize: 10 }} />
                <Tooltip />
                <Bar dataKey="profit">
                  {dailyProfitData.map((entry, index) => (
                    <Cell
                      key={index}
                      fill={entry.profit >= 0 ? '#4caf50' : '#f44336'}
                    />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>
      )}
    </Box>
  );
};
