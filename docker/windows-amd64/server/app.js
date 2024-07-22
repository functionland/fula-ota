const express = require('express');
const cors = require('cors');
const path = require('path');
const axios = require('axios');
const propertiesRouter = require('./routes/properties');
const peerExchangeRouter = require('./routes/peer/exchange');
const generateIdentityRouter = require('./routes/peer/generate-identity');
const accountIdRouter = require('./routes/account/id');
const accountSeedRouter = require('./routes/account/seed');
const dockerRestartRouter = require('./routes/docker/restart');
const poolJoinRouter = require('./routes/pools/join.js');
const chainStatusRouter = require('./routes/chain/status.js');
const { exec } = require('child_process');

const app = express();
const port = 7000;

// Use CORS middleware
app.use(cors());

app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use('/webui/public', express.static(path.join(__dirname, 'public')));

app.set('views', path.join(__dirname, 'views'));
app.set('view engine', 'html');

app.get('/webui/welcome', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'welcome.html'));
});

app.get('/webui/connect-to-wallet', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'connect-to-wallet.html'));
});

app.get('/webui/set-authorizer', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'set-authorizer.html'));
});

app.get('/webui/pools', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'pools.html'));
});

app.get('/webui/home', (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'home.html'));
});

// New route for handling /webui
app.get('/webui', async (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'index.html'));
});

app.use('/api/properties', propertiesRouter);
app.use('/api/peer/exchange', peerExchangeRouter);
app.use('/api/peer/generate-identity', generateIdentityRouter);
app.use('/api/account/id', accountIdRouter);
app.use('/api/account/seed', accountSeedRouter);
app.use('/api/docker/restart', dockerRestartRouter);
app.use('/api/pools/join', poolJoinRouter);
app.use('/api/chain/status', chainStatusRouter);

// Proxy endpoint for fetching pools
app.post('/api/proxy/pool', async (req, res) => {
  console.log("Proxy endpoint hit"); // Add this line
  try {
    const response = await axios.post('https://api.node3.functionyard.fula.network/fula/pool', {}, {
      headers: { 'Content-Type': 'application/json' }
    });
    res.json(response.data);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/proxy/users', async (req, res) => {
  console.log("Proxy endpoint hit for users"); // Add this line
  try {
    const response = await axios.post(
      'https://api.node3.functionyard.fula.network/fula/pool/users', 
      req.body, // Pass the request body as the payload
      {
        headers: { 'Content-Type': 'application/json' }
      }
    );
    res.json(response.data);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get('/api/docker/status', (req, res) => {
  const dockerName = req.query.name;

  exec(`docker ps --filter "name=${dockerName}" --format "{{.Names}}"`, (err, stdout) => {
      if (err) {
          return res.status(500).json({ status: 'not running' });
      }

      if (!stdout.includes(dockerName)) {
          return res.json({ status: 'not running' });
      }

      exec(`docker logs ${dockerName} --tail 20`, (err, logs) => {
          if (err) {
              return res.status(500).json({ status: 'Error', errorLine: err.message });
          }

          const errorLine = logs.split('\n').find(line => line.includes('ERROR'));
          if (errorLine) {
              return res.json({ status: 'Error', errorLine });
          }

          res.json({ status: 'Running' });
      });
  });
});

// Start the main server
app.listen(port, '127.0.0.1', () => {
  console.log(`Main server is running on http://127.0.0.1:${port}`);
});
