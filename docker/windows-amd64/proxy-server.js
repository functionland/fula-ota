const express = require('express');
const { exec } = require('child_process');
const bodyParser = require('body-parser');

const app = express();
const port = 3500;

app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

app.all('*', (req, res) => {
  const { method, headers, originalUrl, body } = req;
  const dataString = JSON.stringify(body);
  const headersString = Object.entries(headers).map(([key, value]) => `-H "${key}: ${value}"`).join(' ');

  const command = `docker exec fula_go curl -s -X ${method} ${headersString} -d "${dataString}" http://localhost:3500${originalUrl}`;

  console.log(`Executing command: ${command}`);

  exec(command, (error, stdout, stderr) => {
    if (error) {
      console.error(`Error: ${error.message}`);
      console.error(`Command: ${command}`);
      return res.status(500).send(`Server error: ${error.message}`);
    }
    if (stderr) {
      console.error(`Stderr: ${stderr}`);
      console.error(`Command: ${command}`);
      return res.status(500).send(`Server error: ${stderr}`);
    }
    res.send(stdout);
  });
});

app.listen(port, '127.0.0.1', () => {
  console.log(`Proxy server is running on http://127.0.0.1:${port}`);
});
