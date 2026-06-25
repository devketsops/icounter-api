const express = require('express');

const app = express();

app.use(express.json());

app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    version: process.env.APP_VERSION || '1.0.0'
  });
});

app.get('/api', (req, res) => {
  res.status(200).json({
    message: 'Welcome to iCOUNTER API',
    environment: process.env.NODE_ENV || 'development'
  });
});

app.get('/api/info', (req, res) => {
  res.status(200).json({
    service: 'icounter-api',
    uptime: process.uptime()
  });
});

app.use((req, res) => {
  res.status(404).json({ error: 'Not Found' });
});

app.use((err, req, res, next) => {
  res.status(500).json({ error: 'Internal Server Error' });
});

module.exports = app;
