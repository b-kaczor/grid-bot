import { Typography } from '@mui/material';
import { useParams } from 'react-router-dom';

export const BotDetail = () => {
  const { id } = useParams<{ id: string }>();

  return (
    <Typography variant="h5">Bot #{id}</Typography>
  );
};
