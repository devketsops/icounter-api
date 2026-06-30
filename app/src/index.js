const app = require('./app');

const PORT = process.env.PORT || 3000;

const server = app.listen(PORT, () => {
  console.log(`iCOUNTER API running on port ${PORT}`);
});

process.on('SIGTERM', () => {
  console.log('SIGTERM received, draining connections...');
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});
