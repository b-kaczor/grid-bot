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
  Chip,
} from '@mui/material';
import { useBotOrders } from '../api/bots.ts';

interface OrderHistoryTableProps {
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

export const OrderHistoryTable = ({ botId }: OrderHistoryTableProps) => {
  const [page, setPage] = useState(0);
  const { data, isLoading } = useBotOrders(botId, page + 1);

  if (isLoading) {
    return (
      <Box>
        {Array.from({ length: 5 }).map((_, i) => (
          <Skeleton key={i} variant="rectangular" height={40} sx={{ mb: 0.5 }} />
        ))}
      </Box>
    );
  }

  if (!data?.orders.length) {
    return (
      <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: 'center' }}>
        No filled orders yet.
      </Typography>
    );
  }

  return (
    <TableContainer component={Paper} variant="outlined">
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell>Filled At</TableCell>
            <TableCell>Level</TableCell>
            <TableCell>Side</TableCell>
            <TableCell align="right">Price</TableCell>
            <TableCell align="right">Avg Fill</TableCell>
            <TableCell align="right">Qty</TableCell>
            <TableCell align="right">Fee</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {data.orders.map((order) => (
            <TableRow key={order.id}>
              <TableCell>{order.filled_at ? formatDate(order.filled_at) : '-'}</TableCell>
              <TableCell>{order.level_index}</TableCell>
              <TableCell>
                <Chip
                  label={order.side.toUpperCase()}
                  size="small"
                  color={order.side === 'buy' ? 'success' : 'error'}
                  variant="outlined"
                />
              </TableCell>
              <TableCell align="right">{order.price}</TableCell>
              <TableCell align="right">{order.avg_fill_price}</TableCell>
              <TableCell align="right">{order.filled_quantity}</TableCell>
              <TableCell align="right">
                {order.fee} {order.fee_coin}
              </TableCell>
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
