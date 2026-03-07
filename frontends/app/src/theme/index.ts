import { createTheme } from '@mui/material/styles';

const theme = createTheme({
  palette: {
    mode: 'dark',
    primary: { main: '#4caf50' },
    secondary: { main: '#f44336' },
    background: {
      default: '#121212',
      paper: '#1e1e1e',
    },
  },
  typography: {
    fontFamily: '"Inter", "Roboto", sans-serif',
    h6: { fontWeight: 600 },
  },
  components: {
    MuiCard: {
      defaultProps: { elevation: 2 },
    },
  },
});

export default theme;
