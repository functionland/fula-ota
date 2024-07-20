const express = require('express');
const { exec } = require('child_process');
const router = express.Router();

router.post('/', (req, res) => {
  const { PeerID, seed } = req.body;
  const command = `docker exec fula_go curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" -d "peer_id=${PeerID}&seed=${seed}" http://localhost:3500/peer/exchange`;

  console.error(`Command: ${command}`);
  exec(command, (error, stdout, stderr) => {
    if (error) {
      console.error(`Error: ${error.message}`);
      return res.status(500).send(`Server error: ${error.message}`);
    }
    if (stderr) {
      console.error(`Stderr: ${stderr}`);
      return res.status(500).send(`Server error: ${stderr}`);
    }
    res.send(stdout);
  });
});

module.exports = router;
