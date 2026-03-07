import { useState } from 'react';
import {
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Paper,
  TablePagination,
  Typography,
  Skeleton,
  Box,
} from '@mui/material';
import { useBotTrades } from '../api/bots.ts';

interface TradeHistoryTableProps {
  botId: number;
}

const formatDate = (iso: string): string => {
  const d = new Date(iso);
  return d.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
};

const ProfitCell = ({ value }: { value: string }) => {
  const num = parseFloat(value);
  const color = num > 0 ? 'success.main' : num < 0 ? 'error.main' : 'text.primary';
  return (
    <Typography variant="body2" color={color}>
      {value}
    </Typography>
  );
};

export const TradeHistoryTable = ({ botId }: TradeHistoryTableProps) => {
  const [page, setPage] = useState(0);
  const { data, isLoading } = useBotTrades(botId, page + 1);

  if (isLoading) {
    return (
      <Box>
        {Array.from({ length: 5 }).map((_, i) => (
          <Skeleton key={i} variant="rectangular" height={40} sx={{ mb: 0.5 }} />
        ))}
      </Box>
    );
  }

  if (!data?.trades.length) {
    return (
      <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: 'center' }}>
        No trades completed yet. Waiting for the first grid cycle.
      </Typography>
    );
  }

  return (
    <TableContainer component={Paper} variant="outlined">
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell>Date</TableCell>
            <TableCell>Level</TableCell>
            <TableCell align="right">Buy Price</TableCell>
            <TableCell align="right">Sell Price</TableCell>
            <TableCell align="right">Qty</TableCell>
            <TableCell align="right">Net Profit</TableCell>
            <TableCell align="right">Fees</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {data.trades.map((trade) => (
            <TableRow key={trade.id}>
              <TableCell>{formatDate(trade.completed_at)}</TableCell>
              <TableCell>{trade.level_index}</TableCell>
              <TableCell align="right">{trade.buy_price}</TableCell>
              <TableCell align="right">{trade.sell_price}</TableCell>
              <TableCell align="right">{trade.quantity}</TableCell>
              <TableCell align="right">
                <ProfitCell value={trade.net_profit} />
              </TableCell>
              <TableCell align="right">{trade.total_fees}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      {data.pagination.total_pages > 1 && (
        <TablePagination
          component="div"
          count={data.pagination.total}
          page={page}
          onPageChange={(_e, newPage) => setPage(newPage)}
          rowsPerPage={data.pagination.per_page}
          rowsPerPageOptions={[data.pagination.per_page]}
        />
      )}
    </TableContainer>
  );
};
